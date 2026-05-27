#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail(){ log "ERROR: $*"; exit 1; }
require_env(){ [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }

require_env DOMAIN
require_env LINODE_API_TOKEN
require_env NODEBALANCER_ID
require_env K8S_NAMESPACE
require_env K8S_SECRET_NAME
require_env ACME_DNS_PROVIDER
require_env VPC_SUBNET_ID

CERT_HOME="${CERT_HOME:-/mnt/cert-data}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backups}"
LOCK_FILE="${LOCK_FILE:-/mnt/cert-data/renew.lock}"
LINODE_API_BASE="${LINODE_API_BASE:-https://api.linode.com/v4}"

mkdir -p "$CERT_HOME" "$BACKUP_ROOT"

exec 9>"$LOCK_FILE"
flock -n 9 || { log "Another process is running. Exiting."; exit 0; }

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
BACKUP_DIR="${BACKUP_ROOT}/${DOMAIN}/${RUN_ID}"
mkdir -p "$BACKUP_DIR"

api_get(){ curl -fsS -H "Authorization: Bearer ${LINODE_API_TOKEN}" -H "Content-Type: application/json" "${LINODE_API_BASE}$1"; }
api_post(){ curl -fsS -X POST -H "Authorization: Bearer ${LINODE_API_TOKEN}" -H "Content-Type: application/json" --data-binary "@$2" "${LINODE_API_BASE}$1"; }
api_put(){ curl -fsS -X PUT -H "Authorization: Bearer ${LINODE_API_TOKEN}" -H "Content-Type: application/json" --data-binary "@$2" "${LINODE_API_BASE}$1"; }
api_delete(){ curl -fsS -X DELETE -H "Authorization: Bearer ${LINODE_API_TOKEN}" "${LINODE_API_BASE}$1"; }

backup_nodebalancer() {
  log "Backing up NodeBalancer"
  api_get "/nodebalancers/${NODEBALANCER_ID}" > "${BACKUP_DIR}/nodebalancer.json"
  api_get "/nodebalancers/${NODEBALANCER_ID}/configs" > "${BACKUP_DIR}/nodebalancer-configs.json"

  HTTPS_CONFIG_ID="$(jq -r '.data[] | select(.port==443 and .protocol=="https") | .id' "${BACKUP_DIR}/nodebalancer-configs.json" | head -n1)"

  if [[ -n "$HTTPS_CONFIG_ID" && "$HTTPS_CONFIG_ID" != "null" ]]; then
    log "Existing HTTPS config found: $HTTPS_CONFIG_ID"
    api_get "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}" > "${BACKUP_DIR}/nodebalancer-config.json"
    api_get "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}/nodes" > "${BACKUP_DIR}/nodebalancer-nodes.json"
    echo "$HTTPS_CONFIG_ID" > "${BACKUP_DIR}/https-config-id.txt"
    echo "update" > "${BACKUP_DIR}/nb-operation.txt"
    return
  fi

  log "No HTTPS config found. Looking for HTTP/80 config to clone."
  HTTP_CONFIG_ID="$(jq -r '.data[] | select(.port==80 and .protocol=="http") | .id' "${BACKUP_DIR}/nodebalancer-configs.json" | head -n1)"
  [[ -n "$HTTP_CONFIG_ID" && "$HTTP_CONFIG_ID" != "null" ]] || fail "No HTTP config found to clone"

  api_get "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTP_CONFIG_ID}" > "${BACKUP_DIR}/nodebalancer-http-config.json"
  api_get "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTP_CONFIG_ID}/nodes" > "${BACKUP_DIR}/nodebalancer-http-nodes.json"

  echo "$HTTP_CONFIG_ID" > "${BACKUP_DIR}/http-config-id.txt"
  echo "create" > "${BACKUP_DIR}/nb-operation.txt"
}

backup_k8s_secret() {
  log "Backing up Kubernetes Secret ${K8S_NAMESPACE}/${K8S_SECRET_NAME}"
  if kubectl -n "$K8S_NAMESPACE" get secret "$K8S_SECRET_NAME" >/dev/null 2>&1; then
    kubectl -n "$K8S_NAMESPACE" get secret "$K8S_SECRET_NAME" -o yaml > "${BACKUP_DIR}/k8s-secret-${K8S_SECRET_NAME}.yaml"
  else
    log "Secret does not exist yet. Skipping backup."
  fi
}

issue_or_renew_cert() {
  log "Issuing/renewing cert using ${ACME_DNS_PROVIDER}"
  export LE_WORKING_DIR="$CERT_HOME/.acme.sh"
  mkdir -p "$LE_WORKING_DIR"

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  domain_args="-d ${DOMAIN}"
  [[ "${INCLUDE_WILDCARD:-false}" == "true" ]] && domain_args="${domain_args} -d *.${DOMAIN}"

  # shellcheck disable=SC2086
  ACME_FORCE_ARG=""
  [[ "${FORCE_RENEW:-false}" == "true" ]] && ACME_FORCE_ARG="--force"

  /root/.acme.sh/acme.sh --issue --dns "${ACME_DNS_PROVIDER}" ${domain_args} --home "$LE_WORKING_DIR" ${ACME_FORCE_ARG} || true

  CERT_PATH="${CERT_HOME}/certs/${DOMAIN}"
  mkdir -p "$CERT_PATH"

  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --home "$LE_WORKING_DIR" \
    --fullchain-file "${CERT_PATH}/fullchain.pem" \
    --key-file "${CERT_PATH}/privkey.pem"

  FULLCHAIN="${CERT_PATH}/fullchain.pem"
  PRIVATEKEY="${CERT_PATH}/privkey.pem"

  [[ -s "$FULLCHAIN" ]] || fail "fullchain.pem missing"
  [[ -s "$PRIVATEKEY" ]] || fail "privkey.pem missing"

  cp "$FULLCHAIN" "${BACKUP_DIR}/new-fullchain.pem"
  cp "$PRIVATEKEY" "${BACKUP_DIR}/new-privkey.pem"
}

validate_cert_key_match() {
  log "Validating cert/key match"
  cert_pub="$(openssl x509 -in "$FULLCHAIN" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)"
  key_pub="$(openssl pkey -in "$PRIVATEKEY" -pubout -outform DER | openssl dgst -sha256)"
  [[ "$cert_pub" == "$key_pub" ]] || fail "Certificate and private key do not match"
}

build_payload() {
  operation="$(cat "${BACKUP_DIR}/nb-operation.txt")"

  if [[ "$operation" == "update" ]]; then
    jq --rawfile ssl_cert "$FULLCHAIN" --rawfile ssl_key "$PRIVATEKEY" \
      '.ssl_cert=$ssl_cert | .ssl_key=$ssl_key' \
      "${BACKUP_DIR}/nodebalancer-config.json" > "${BACKUP_DIR}/nodebalancer-config-updated.json"
  else
    jq --rawfile ssl_cert "$FULLCHAIN" --rawfile ssl_key "$PRIVATEKEY" \
      '{
        port: 443,
        protocol: "https",
        algorithm: .algorithm,
        stickiness: .stickiness,
        check: .check,
        check_interval: .check_interval,
        check_timeout: .check_timeout,
        check_attempts: .check_attempts,
        check_path: .check_path,
        check_body: .check_body,
        check_passive: .check_passive,
        proxy_protocol: .proxy_protocol,
        cipher_suite: .cipher_suite,
        ssl_cert: $ssl_cert,
        ssl_key: $ssl_key
      }' "${BACKUP_DIR}/nodebalancer-http-config.json" > "${BACKUP_DIR}/nodebalancer-config-create.json"
  fi
}

update_nodebalancer() {
  operation="$(cat "${BACKUP_DIR}/nb-operation.txt")"

  if [[ "$operation" == "update" ]]; then
    HTTPS_CONFIG_ID="$(cat "${BACKUP_DIR}/https-config-id.txt")"
    log "Updating existing HTTPS config $HTTPS_CONFIG_ID"
    api_put "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}" "${BACKUP_DIR}/nodebalancer-config-updated.json" > "${BACKUP_DIR}/nodebalancer-update-response.json"
    return
  fi

  log "Creating new HTTPS config"
  api_post "/nodebalancers/${NODEBALANCER_ID}/configs" "${BACKUP_DIR}/nodebalancer-config-create.json" > "${BACKUP_DIR}/nodebalancer-create-response.json"

  HTTPS_CONFIG_ID="$(jq -r '.id' "${BACKUP_DIR}/nodebalancer-create-response.json")"
  [[ -n "$HTTPS_CONFIG_ID" && "$HTTPS_CONFIG_ID" != "null" ]] || fail "Failed to create HTTPS config"
  echo "$HTTPS_CONFIG_ID" > "${BACKUP_DIR}/https-config-id.txt"

  log "Copying backend nodes to HTTPS config $HTTPS_CONFIG_ID"

  jq -c '.data[]' "${BACKUP_DIR}/nodebalancer-http-nodes.json" | while read -r node; do
    node_id="$(echo "$node" | jq -r '.id')"
    node_payload="${BACKUP_DIR}/node-create-${node_id}.json"

    echo "$node" | jq \
      --arg suffix "-https" \
      --argjson subnet_id "$VPC_SUBNET_ID" \
      '{
        address: .address,
        label: ((.label + $suffix) | .[0:32]),
        weight: .weight,
        mode: .mode,
        subnet_id: $subnet_id
      }' > "$node_payload"

    api_post "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}/nodes" "$node_payload" > "${node_payload}.response"
  done
}

validate_live_cert() {
  [[ -n "${VALIDATION_HOST:-}" ]] || return 0

  local port
  port="${VALIDATION_PORT:-443}"

  local initial_sleep
  initial_sleep="${POST_UPDATE_VALIDATE_SLEEP:-30}"

  log "Waiting ${initial_sleep}s for NodeBalancer HTTPS config to become active"
  sleep "${initial_sleep}"

  log "Validating live certificate from ${VALIDATION_HOST}:${port}"

  for i in $(seq 1 10); do

    if echo | openssl s_client \
      -servername "$DOMAIN" \
      -connect "${VALIDATION_HOST}:${port}" \
      2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates \
      > "${BACKUP_DIR}/live-cert-validation.txt"; then

      log "Live certificate validation succeeded"
      return 0
    fi

    log "Live certificate not ready yet. Retry ${i}/10"
    sleep 10
  done

  log "Live certificate validation failed after retries"
  return 1
}

update_k8s_secret() {
  log "Updating Kubernetes TLS Secret ${K8S_NAMESPACE}/${K8S_SECRET_NAME}"
  kubectl -n "$K8S_NAMESPACE" create secret tls "$K8S_SECRET_NAME" \
    --cert="$FULLCHAIN" \
    --key="$PRIVATEKEY" \
    --dry-run=client -o yaml | kubectl apply -f -
}

rollback_nodebalancer() {
  log "Rolling back NodeBalancer if required"
  operation="$(cat "${BACKUP_DIR}/nb-operation.txt" 2>/dev/null || true)"

  if [[ "$operation" == "update" && -s "${BACKUP_DIR}/nodebalancer-config.json" ]]; then
    HTTPS_CONFIG_ID="$(cat "${BACKUP_DIR}/https-config-id.txt")"
    api_put "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}" "${BACKUP_DIR}/nodebalancer-config.json" || true
  fi

  if [[ "$operation" == "create" && -s "${BACKUP_DIR}/https-config-id.txt" ]]; then
    HTTPS_CONFIG_ID="$(cat "${BACKUP_DIR}/https-config-id.txt")"
    log "Deleting newly created HTTPS config $HTTPS_CONFIG_ID"
    api_delete "/nodebalancers/${NODEBALANCER_ID}/configs/${HTTPS_CONFIG_ID}" || true
  fi
}

rollback_k8s_secret() {
  [[ -s "${BACKUP_DIR}/k8s-secret-${K8S_SECRET_NAME}.yaml" ]] && kubectl apply -f "${BACKUP_DIR}/k8s-secret-${K8S_SECRET_NAME}.yaml" || true
}

cleanup_old_backups() {
  keep="${BACKUP_RETENTION_COUNT:-10}"
  ls -1dt "${BACKUP_ROOT}/${DOMAIN}"/* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -rf
}

main() {
  log "Starting certificate automation for $DOMAIN"
  log "Backup directory: $BACKUP_DIR"

  backup_nodebalancer
  backup_k8s_secret
  issue_or_renew_cert
  validate_cert_key_match
  build_payload

  if ! update_nodebalancer; then
    rollback_nodebalancer
    fail "NodeBalancer update failed"
  fi

  if ! validate_live_cert; then
    rollback_nodebalancer
    fail "Live cert validation failed"
  fi

  if ! update_k8s_secret; then
    rollback_k8s_secret
    rollback_nodebalancer
    fail "Kubernetes Secret update failed"
  fi

  cleanup_old_backups
  log "Certificate automation completed successfully"
}

main "$@"
