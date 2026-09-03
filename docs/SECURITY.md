# DevSecOps Control Mapping

A control-by-control breakdown of what's implemented and which compliance
theme it supports — useful as interview talking points and as a template for
real client work (SOC 2 / PCI DSS / ISO 27001).

| Control | Implementation | Why it matters |
|---|---|---|
| No static AWS credentials in the cluster | IRSA (`terraform/eks.tf`) — pods assume an IAM role via OIDC federation | Removes long-lived secrets as an attack surface; credentials are short-lived and auto-rotated |
| Least-privilege IAM | Custom `ai_service_permissions` policy scoped to only `bedrock:InvokeModel` and `secretsmanager:GetSecretValue` on a scoped resource path | Blast radius of a compromised pod is minimal |
| Image supply-chain integrity | ECR `image_tag_mutability = "IMMUTABLE"`, scan-on-push, KMS encryption | A pushed tag can't be silently swapped; every image is scanned before it can be pulled |
| CI-time vulnerability gate | Trivy scan in GitHub Actions, `exit-code: 1` on Critical/High | Vulnerable images never reach the registry, let alone the cluster |
| No long-lived CI credentials | GitHub Actions OIDC → AWS IAM role assumption (`id-token: write`) | No AWS access keys stored as GitHub secrets |
| Non-root containers | Dockerfile creates `appuser` (UID 10001); Helm `securityContext.runAsNonRoot: true` | Limits impact of a container-breakout style vulnerability |
| Read-only root filesystem | `securityContext.readOnlyRootFilesystem: true`, `emptyDir` for `/tmp` only | Prevents runtime tampering / malware persistence inside the container |
| Dropped Linux capabilities | `capabilities.drop: ["ALL"]` | Removes unnecessary kernel-level privileges |
| Network segmentation | Kubernetes `NetworkPolicy` — deny-all by default, explicit allow for ingress + DNS + HTTPS egress | Contains lateral movement if a pod is compromised |
| Availability during patching | `PodDisruptionBudget` (`minAvailable: 1`) + `HorizontalPodAutoscaler` | Rolling updates and node drains don't cause an outage — supports the 99.9% SLA pattern |
| GitOps audit trail | ArgoCD `selfHeal` + `prune`, all changes via Git PRs | Every production change is attributable to a commit/author — direct evidence for SOC 2 change-management controls |
| Encrypted state | Terraform S3 backend with `encrypt = true` + DynamoDB locking | Prevents concurrent-apply corruption and protects state (which can contain sensitive outputs) |
| Control-plane audit logging | EKS `cluster_enabled_log_types` → CloudWatch (api, audit, authenticator, controllerManager, scheduler) | Feeds the same GuardDuty/Wazuh/CloudWatch triage pipeline this project's own AI service is modeled on |
| Observability | `/metrics` Prometheus endpoint, `/healthz` + `/readyz` probes | Standard SRE golden-signals pattern; ready to scrape from an existing Prometheus/Grafana stack |

## Threat model notes (for discussion in interviews)

- **Public EKS endpoint** is enabled for demo convenience
  (`cluster_endpoint_public_access = true`, open CIDR). In a real production
  build this would be restricted to a VPN/bastion CIDR or set to
  private-only with a peered/transit-gateway access path — called out
  explicitly in `terraform/eks.tf` as a known showcase simplification.
- **Single NAT gateway** is a cost/availability trade-off for a demo cluster;
  production would use one NAT per AZ for HA.
- **LLM prompt-injection risk**: the `/v1/triage` endpoint feeds raw alert
  text into a model prompt. The rule-based fallback path is intentionally
  kept as a deterministic backstop, and the Bedrock JSON response is parsed
  strictly (not executed) — no tool-use / code-execution is exposed to the
  model, which removes the main injection blast radius.
