output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.ai_incident_assistant.repository_url
}

output "ai_service_irsa_role_arn" {
  description = "Attach this role ARN to the K8s ServiceAccount via the eks.amazonaws.com/role-arn annotation"
  value       = module.ai_service_irsa_role.iam_role_arn
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
