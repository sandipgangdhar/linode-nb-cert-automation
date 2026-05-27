FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    openssl \
    bind-tools \
    ca-certificates \
    py3-pip \
    kubectl

# Install acme.sh for lightweight ACME automation
RUN curl https://get.acme.sh | sh -s email=admin@example.com
ENV PATH="/root/.acme.sh:${PATH}"

COPY scripts/renew-and-deploy.sh /usr/local/bin/renew-and-deploy.sh
RUN chmod +x /usr/local/bin/renew-and-deploy.sh

ENTRYPOINT ["/usr/local/bin/renew-and-deploy.sh"]
