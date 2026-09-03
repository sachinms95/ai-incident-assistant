# Deployment Guide — from zero to a running AI service on EKS

This walks through every step, explaining *why*, not just *what*, so it
doubles as interview-ready talking points.

## Prerequisites

- AWS account with admin access (or scoped IAM permissions for VPC/EKS/IAM/ECR)
- Installed locally: `terraform` (>=1.7), `aws-cli` (v2), `kubectl`, `helm`, `docker`
- An S3 bucket + DynamoDB table for Terraform remote state (create once, see
  `terraform/providers.tf` comments) — keeps state safe and lockable for team use
- A GitHub repo to hold this code (ArgoCD and GitHub Actions both point at it)

## Step 1 — Provision the cloud infrastructure

```bash
cd terraform
terraform init
terraform plan   # review: VPC, EKS cluster, node group, ECR repo, IRSA role
terraform apply
```

**What gets created and why:**
- **VPC** (3 AZs, private subnets for workloads, public subnets only for NAT/ALB)
  — reduces blast radius; nodes have no direct public IPs.
- **EKS cluster** with a managed node group — AWS patches the control plane;
  we own node-level and workload-level hardening.
- **IRSA role** (`ai_service_irsa_role`) — lets the pod call Bedrock and
  Secrets Manager using short-lived, auto-rotated credentials instead of a
  static AWS access key baked into a Secret. This is the same pattern as
  least-privilege IAM used at Amplicomm/Pay10.
- **ECR repository** — private registry with scan-on-push and immutable tags
  (a pushed tag can never be silently overwritten — supply-chain integrity).

Grab the outputs:

```bash
terraform output
# cluster_name, ecr_repository_url, ai_service_irsa_role_arn, configure_kubectl
```

## Step 2 — Connect kubectl to the new cluster

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-incident-assistant-eks
kubectl get nodes    # should show 2 Ready nodes
```

## Step 3 — Wire the IRSA role into the Helm chart

Copy the `ai_service_irsa_role_arn` Terraform output into
`helm/ai-incident-assistant/values.yaml`:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "<paste the ARN here>"
image:
  repository: "<paste ecr_repository_url here>"
```

## Step 4 — Build and push the first image manually (bootstrap only)

After this, CI does it automatically — but the first push has to exist
before ArgoCD has anything to deploy.

```bash
cd app
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin <ECR_REGISTRY>

docker build -t ai-incident-assistant:v1 .
docker tag ai-incident-assistant:v1 <ECR_REPOSITORY_URL>:v1
docker push <ECR_REPOSITORY_URL>:v1
```

Update `values.yaml` → `image.tag: "v1"`, commit and push to `main`.

## Step 5 — Install ArgoCD on the cluster (one-time)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

Port-forward to reach the UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080, login as admin
```

## Step 6 — Register the app with ArgoCD (GitOps entry point)

Edit `argocd/application.yaml`: set `repoURL` to your actual GitHub repo URL.

```bash
kubectl apply -f argocd/application.yaml
```

From this point on, **the Git repo is the source of truth**. ArgoCD polls it
every ~3 minutes (or reacts instantly via webhook), and:
- `automated.prune: true` deletes cluster resources removed from Git
- `automated.selfHeal: true` reverts any manual `kubectl edit` drift back to
  what's in Git — this is the audit-friendly guarantee compliance teams want
  for SOC 2 / ISO 27001 change-control evidence.

## Step 7 — Verify

```bash
kubectl -n ai-incident-assistant get pods,svc,hpa,pdb
kubectl -n ai-incident-assistant port-forward svc/ai-incident-assistant 8080:80

curl -X POST http://localhost:8080/v1/triage \
  -H "Content-Type: application/json" \
  -d '{"source":"GuardDuty","title":"UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration","raw_message":"Credentials used from unusual IP","resource":"i-0abc123"}'
```

Expected: a JSON response with `severity: "critical"`, a summary, and a
suggested first action.

## Step 8 — The full loop (day 2 onward)

1. Change `app/main.py` (e.g. add a new alert source).
2. Push to `main`.
3. GitHub Actions builds the image, runs Trivy (fails the build on
   Critical/High CVEs), pushes to ECR, bumps `values.yaml`'s `image.tag`,
   commits back to the repo.
4. ArgoCD detects the Git change and rolls out the new image with a
   standard Kubernetes rolling update (respecting the PDB, so there's no
   downtime).

No one ever runs `kubectl apply` or `helm upgrade` by hand against the
cluster — every change is reviewable in Git history, which is exactly the
audit trail a FinTech/CBUAE-regulated environment needs.

## Teardown

```bash
kubectl delete -f argocd/application.yaml
cd terraform && terraform destroy
```
