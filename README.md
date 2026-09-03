# AI Incident Triage Assistant — DevOps Showcase

A production-style GitOps platform that deploys an AI-powered incident-triage
microservice to Amazon EKS. Built to demonstrate the same patterns used in
production at Pay10 UAE and Amplicomm/Truflo.ai: Infrastructure as Code,
container orchestration, security-first CI/CD, and GitOps delivery.

**What it does:** takes a raw security/ops alert (from GuardDuty, Wazuh,
CloudWatch, Zabbix, etc.), classifies severity with an LLM (Amazon Bedrock /
Claude, with a deterministic rule-based fallback), and returns a plain-English
summary and a concrete first remediation step — the same triage pattern that
cut mean incident-response time by 40% at Pay10, packaged as a portfolio
project.

## Stack

| Layer | Tool |
|---|---|
| IaC | Terraform (VPC, EKS, IAM/IRSA, ECR) |
| Orchestration | Amazon EKS (Kubernetes 1.30) |
| App | Python / FastAPI, Bedrock (Claude) + rule-based fallback |
| Packaging | Docker (multi-stage, non-root, distroless-style slim runtime) |
| Registry | Amazon ECR (image scanning, immutable tags) |
| Delivery | Helm chart + ArgoCD (GitOps, automated sync + self-heal) |
| CI | GitHub Actions (OIDC to AWS, Trivy scan gate, ECR push) |
| Observability | Prometheus metrics endpoint, CloudWatch control-plane logs |
| Security | IRSA (no static AWS creds in pods), NetworkPolicy default-deny, PDB, HPA |

## Architecture

```
Developer
   │  git push (app/ code change)
   ▼
GitHub Actions ── OIDC ──▶ AWS IAM Role (no long-lived keys)
   │  1. docker build
   │  2. Trivy scan (fails build on Critical/High CVEs)
   │  3. push image ──────────────────────────────▶ Amazon ECR
   │  4. bump helm values.yaml image.tag
   ▼
Git repo (source of truth) ◀──────── ArgoCD watches this repo
                                        │  auto-sync + self-heal
                                        ▼
                              Amazon EKS cluster
                              ┌─────────────────────────────┐
                              │ ai-incident-assistant ns     │
                              │  • Deployment (2-6 replicas) │
                              │  • HPA (CPU 70%)             │
                              │  • PDB (minAvailable: 1)     │
                              │  • NetworkPolicy (deny-all + │
                              │    explicit allow)           │
                              │  • ServiceAccount ── IRSA ──▶│── AWS Bedrock
                              │                               │── Secrets Manager
                              └─────────────────────────────┘
                                        ▲
                              Prometheus scrapes /metrics
```

Networking: a single VPC across 3 AZs, private subnets for the EKS
nodes/pods, public subnets only for the NAT gateway and (optionally) an
internet-facing ALB. This mirrors the AWS Well-Architected pattern used for
Truflo.ai.

## Repo layout

```
terraform/    VPC, EKS, IAM/IRSA, ECR — `terraform apply` provisions everything
app/          FastAPI service + Dockerfile
helm/         Helm chart for the service (values.yaml drives all config)
argocd/       ArgoCD Application manifest (GitOps entry point)
.github/      CI pipeline: build → scan → push → bump Helm values
docs/         Deployment walkthrough + security notes
```

## Quick start

See [`docs/DEPLOYMENT_GUIDE.md`](docs/DEPLOYMENT_GUIDE.md) for the full,
step-by-step walkthrough (explained from scratch). Short version:

```bash
# 1. Provision infrastructure
cd terraform
terraform init
terraform apply

# 2. Point kubectl at the new cluster
aws eks update-kubeconfig --region ap-south-1 --name ai-incident-assistant-eks

# 3. Install ArgoCD (one-time, if not already on the cluster)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 4. Register the app with ArgoCD (GitOps from here on — no manual helm installs)
kubectl apply -f argocd/application.yaml

# 5. Push to `app/` → GitHub Actions builds, scans, pushes to ECR, bumps Helm
#    values → ArgoCD auto-syncs the new image to the cluster.
```

## Why this project

Every piece maps to something used in production, not just a tutorial copy:

- **Terraform IaC** → same automation pattern that cut provisioning time 70% at Pay10.
- **IRSA over static creds** → least-privilege access, no secrets baked into pods.
- **Trivy scan-gate in CI** → matches SAST/DAST + vulnerability-remediation practice.
- **ArgoCD self-heal + prune** → drift protection, audit-friendly (SOC 2 / ISO 27001 evidence trail).
- **AI-based triage** → direct analogue of the GuardDuty/Wazuh/CloudWatch alert
  correlation work that reduced mean triage time by 40%.

See [`docs/SECURITY.md`](docs/SECURITY.md) for the full DevSecOps control mapping.
# ai-incident-assistant
