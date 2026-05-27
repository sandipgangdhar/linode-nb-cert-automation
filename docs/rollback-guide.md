# Rollback Guide

Backups are stored under:

```text
/mnt/backups/<domain>/<timestamp>/
```

Each run stores:

```text
nodebalancer.json
nodebalancer-config.json
nodebalancer-nodes.json
k8s-secret-<name>.yaml
new-fullchain.pem
new-privkey.pem
```

## Rollback Kubernetes Secret

```bash
kubectl apply -f /mnt/backups/<domain>/<timestamp>/k8s-secret-<name>.yaml
```

## Rollback NodeBalancer Config

```bash
curl -X PUT \
  -H "Authorization: Bearer $LINODE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @nodebalancer-config.json \
  https://api.linode.com/v4/nodebalancers/<nodebalancer-id>/configs/<config-id>
```
