# Deployment Guide

## 1. Create GitHub repository

```bash
gh repo create linode-nb-cert-automation --private --source=. --remote=origin --push
```

Or manually create a repository in GitHub and push:

```bash
git init
git add .
git commit -m "Initial commit: Linode NodeBalancer SSL automation"
git branch -M main
git remote add origin git@github.com:<your-user>/linode-nb-cert-automation.git
git push -u origin main
```

## 2. Build container image

```bash
docker build -t ghcr.io/<your-user>/linode-nb-cert-automation:0.1.0 .
docker push ghcr.io/<your-user>/linode-nb-cert-automation:0.1.0
```

## 3. Configure manifests

Update:

- `manifests/03-configmap.yaml`
- `manifests/02-secret-template.yaml`
- `manifests/05-cronjob.yaml`

## 4. Deploy

```bash
kubectl apply -f manifests/
```

## 5. Manual test run

```bash
kubectl -n nb-cert-automation create job --from=cronjob/nb-cert-automation nb-cert-automation-manual-test
kubectl -n nb-cert-automation logs -f job/nb-cert-automation-manual-test
```
