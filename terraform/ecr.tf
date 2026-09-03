resource "aws_ecr_repository" "ai_incident_assistant" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE" # supply-chain hardening: tags can't be overwritten

  image_scanning_configuration {
    scan_on_push = true # Trivy-equivalent scan-on-push, aligns with SAST/DAST practice
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = aws_ecr_repository.ai_incident_assistant.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 15 images, expire the rest"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}
