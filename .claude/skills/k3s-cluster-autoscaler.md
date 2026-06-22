---
name: k3s-cluster-autoscaler
description: Guide for setting up Node Auto Scaling on K3S using Cluster Autoscaler + AWS Auto Scaling Group. Use when user asks about node scaling, Cluster Autoscaler, ASG, Karpenter alternatives, or EC2 auto scaling on K3S.
---

You are helping set up Node Auto Scaling for a K3S cluster running on EC2, using Cluster Autoscaler + AWS Auto Scaling Group (not Karpenter, which requires EKS).

## Architecture
```
Traffic increases
  → HPA scales pods (more replicas)
  → Node is full → Pods go Pending
  → Cluster Autoscaler detects Pending pods
  → Calls AWS ASG API → SetDesiredCapacity++
  → ASG launches new EC2 from Launch Template
  → EC2 userdata runs K3S agent → joins cluster
  → Pods get scheduled

Traffic decreases
  → HPA scales pods down
  → Node underutilized for 10 min
  → Cluster Autoscaler drains node
  → Terminates EC2 instance
```

## Why NOT Karpenter
Karpenter is EKS-only — its AWS provider uses EKS bootstrap scripts and node registration. K3S is self-managed and not compatible. Cluster Autoscaler + ASG is the correct path for K3S.

## AWS Console Setup (5 steps)

### Step 1 — SSM Parameter Store
Store K3S join credentials so worker userdata can fetch them at boot.

Get token from master:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Create two parameters in AWS Console → Systems Manager → Parameter Store:

| Name | Type | Value |
|---|---|---|
| `/my-k3s-cluster/k3s/server-url` | String | `https://<MASTER_PRIVATE_IP>:6443` |
| `/my-k3s-cluster/k3s/node-token` | SecureString | `<token value>` |

### Step 2 — IAM Role for Worker Nodes (`k3s-worker-role`)
- Trusted entity: EC2
- Attach: `AmazonSSMManagedInstanceCore`
- Inline policy (for SSM param access):
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ssm:GetParameter"],
    "Resource": "arn:aws:ssm:*:*:parameter/my-k3s-cluster/k3s/*"
  }]
}
```

### Step 3 — IAM Role for Master (`k3s-master-role`)
- Trusted entity: EC2
- Attach: `AmazonSSMManagedInstanceCore`
- Inline policy (for Cluster Autoscaler to call ASG API):
```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    }
  ]
}
```

**After creating:** Attach to the existing K3S Master EC2 → Actions → Security → Modify IAM role

### Step 4 — Launch Template (`k3s-worker-template`)
- AMI: Amazon Linux 2 (or same as master)
- Instance type: t3.medium minimum
- IAM profile: `k3s-worker-role`
- Security group: same as master (needs port 6443 open master↔worker)
- User data:
```bash
#!/bin/bash
set -e
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
K3S_SERVER_URL=$(aws ssm get-parameter \
  --name "/my-k3s-cluster/k3s/server-url" \
  --region $REGION \
  --query "Parameter.Value" --output text)
K3S_TOKEN=$(aws ssm get-parameter \
  --name "/my-k3s-cluster/k3s/node-token" \
  --region $REGION \
  --with-decryption \
  --query "Parameter.Value" --output text)
curl -sfL https://get.k3s.io | K3S_URL="$K3S_SERVER_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - agent
```

### Step 5 — Auto Scaling Group (`k3s-workers-asg`)
- Launch template: `k3s-worker-template`
- VPC + Subnets: same as master
- Min: 0, Max: 5, Desired: 1
- Required tags (Cluster Autoscaler uses these to discover the ASG):

| Key | Value |
|---|---|
| `k8s.io/cluster-autoscaler/enabled` | `true` |
| `k8s.io/cluster-autoscaler/my-k3s-cluster` | `owned` |

## GitOps Files (in iac-ops repo)

```
GitOps/
└── apps/
│   ├── base/
│   │   └── cluster-autoscaler/
│   │       ├── rbac.yaml          ← ServiceAccount + RBAC
│   │       ├── configmap.yaml     ← cluster name + region
│   │       ├── deployment.yaml    ← Cluster Autoscaler pod
│   │       └── kustomization.yaml
│   └── overlays/
│       └── dev/
│           └── cluster-autoscaler/
│               └── kustomization.yaml
└── argocd/
    └── applications/
        └── dev/
            └── cluster-autoscaler.yml
```

### Key deployment.yaml notes
- Runs on master node via `nodeSelector: node-role.kubernetes.io/master: "true"`
- Tolerates both `master` and `control-plane` taints (K3S version-dependent)
- Image version must match K3S Kubernetes minor version:
  ```bash
  k3s --version   # check version
  kubectl version # alternative
  ```
  ```yaml
  image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.30.0  # match minor ver
  ```
- Uses `--node-group-auto-discovery` to find ASG by tags automatically

### configmap.yaml
`cluster-name` must match exactly:
1. The value in `configmap.yaml`
2. ASG tag key: `k8s.io/cluster-autoscaler/<cluster-name>`
3. SSM parameter path: `/<cluster-name>/k3s/...`

## Deployment Steps
```bash
# 1. Push files to GitHub
git add .
git commit -m "add cluster-autoscaler"
git push

# 2. Register ArgoCD Application (one-time)
kubectl apply -f GitOps/argocd/applications/dev/cluster-autoscaler.yml

# 3. Verify pod is running
kubectl get pods -n kube-system | grep cluster-autoscaler

# 4. Check logs
kubectl logs -n kube-system -l app=cluster-autoscaler
```

## Pre-push Checklist
- [ ] K3S version checked → image tag updated in deployment.yaml
- [ ] SSM Parameter Store: server-url and node-token created
- [ ] IAM Role `k3s-master-role` attached to master EC2
- [ ] IAM Role `k3s-worker-role` created
- [ ] Launch Template created with correct userdata
- [ ] ASG created with correct tags (both k8s.io/cluster-autoscaler/ tags)
- [ ] cluster-name consistent across configmap, ASG tags, SSM paths
- [ ] Security group allows port 6443 (worker→master) and 10250 (master→worker)

## Troubleshooting

### Pod not found after apply
```bash
# Check ArgoCD application status
kubectl get application -n argocd cluster-autoscaler-dev
kubectl describe application -n argocd cluster-autoscaler-dev
```
Most likely: forgot to `kubectl apply` the ArgoCD Application manifest, or haven't pushed to GitHub yet.

### Cluster Autoscaler running but nodes not scaling
```bash
kubectl logs -n kube-system -l app=cluster-autoscaler | grep -i "scale\|error\|warn"
```
Check:
- ASG tags match cluster-name in configmap exactly
- Master IAM role has Cluster Autoscaler policy attached
- ASG desired < max

### Worker EC2 launches but doesn't join cluster
- Check EC2 userdata logs: `/var/log/cloud-init-output.log`
- Check SSM parameters exist and have correct values
- Check security group allows port 6443 from worker subnet to master

### Scale down not happening
Default wait is 10 minutes of underutilization. Also won't scale down if node has:
- Standalone pods (no controller)
- PodDisruptionBudget blocking eviction
- Pods with local storage