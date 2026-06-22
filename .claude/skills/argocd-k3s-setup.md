---
name: argocd-k3s-setup
description: Guide and troubleshooter for setting up ArgoCD on k3s on EC2 with GitOps and ECR. Use when user asks about ArgoCD, k3s, GitOps setup, or related errors.
---

You are helping set up a GitOps pipeline with ArgoCD on k3s running on EC2, using GitHub Actions and ECR (public.ecr.aws) as the container registry.

## Architecture
```
repo: app source code
    ↓ push code
GitHub Actions → build image → push to ECR
    ↓ update image tag in iac-ops/kustomization.yaml
repo: iac-ops (manifests)
    ↓ ArgoCD watches for changes
ArgoCD → kubectl apply → k3s on EC2
```

## Project Structure (iac-ops repo)
```
GitOps/
  apps/
    base/<app>/          # deployment.yaml, service.yaml, kustomization.yaml
    overlays/
      dev/<app>/         # kustomization.yaml (image tag override)
      prod/<app>/        # kustomization.yaml (image tag override)
  argocd/
    install/             # kustomization.yaml (references ArgoCD install.yaml)
    projects/            # AppProject definitions
    applications/
      dev/<app>.yml      # ArgoCD Application manifest
      prod/<app>.yml     # ArgoCD Application manifest
terraform/
  eks/                   # Not used unless running terraform apply
```

## Installation Order
1. `kubectl create namespace argocd`
2. `kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
3. `kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s`
4. `kubectl apply -f GitOps/argocd/projects/sample-project.yaml`
5. `kubectl apply -f GitOps/argocd/applications/dev/<app>.yml`
6. `kubectl apply -f GitOps/argocd/applications/prod/<app>.yml`

## Common Errors & Fixes

### k3s kubeconfig permission denied
```
error: open /etc/rancher/k3s/k3s.yaml: permission denied
```
**Fix:**
```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

### ArgoCD CRD annotation too large
```
The CustomResourceDefinition "..." is invalid: metadata.annotations: Too long
```
**Fix:** Use `--server-side` flag:
```bash
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### kustomize base path resolves incorrectly (infinite loop)
```
accumulation err='accumulating resources from '../../../base/<app>': must resolve to a file'
```
**Cause:** `GitOps/apps/base/<app>/kustomization.yaml` has wrong resources — pointing back to itself instead of deployment.yaml/service.yaml.

**Fix:** base kustomization.yaml should be:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

### ArgoCD stuck on cached state (Unknown sync status after fix)
**Fix:** Force hard refresh:
```bash
kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### TLS handshake timeout / API server unresponsive
**Cause:** EC2 instance too small — RAM exhausted running k3s + ArgoCD.
**Minimum:** t3.medium (4GB RAM). t3.small (2GB) is too tight.
**Fix:** Upgrade EC2 instance type or add swap:
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### ImagePullBackOff
**Cause:** Image not pushed to ECR yet, or wrong image URL in kustomization.yaml.
**Check:** `kubectl describe pod -n <namespace> | grep -A 5 "Events:"`
**Fix:** Push image via GitHub Actions workflow, or correct image URL in overlay kustomization.yaml.

## ECR Notes
- This project uses **Public ECR**: `public.ecr.aws/r8m4q7l9/my-website`
- Both dev and prod overlays use the same ECR registry
- Image tag is updated automatically by GitHub Actions reusable workflow in iac-ops
- GitHub Secrets required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GH_PAT`

## Useful Commands
```bash
# Check all ArgoCD apps
kubectl get applications -n argocd

# Check pods per environment
kubectl get pods -n dev
kubectl get pods -n prod

# Check ArgoCD pods
kubectl get pods -n argocd

# Force sync
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Check error details
kubectl describe application <app> -n argocd | grep "Message:"

# Check RAM
free -h
```
