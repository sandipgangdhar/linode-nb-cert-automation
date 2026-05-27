# Security Notes

## API Tokens

Use the least privileged Linode API token possible.

The token needs access to update NodeBalancer configuration.

## Kubernetes RBAC

The ServiceAccount should only have access to the target namespace and Secret.

## DNS Provider Token

For DNS-01 challenge, use a restricted DNS API token limited to the required zone.

## Backup Protection

Backups contain private keys. Protect the PVC and restrict access to the namespace.

## Recommended Hardening

- Use private image registry
- Enable Kubernetes audit logging
- Restrict exec access into the automation pod
- Encrypt backups if long-term retention is required
- Use external secret management where possible
