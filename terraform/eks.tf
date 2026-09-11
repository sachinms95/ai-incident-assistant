module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${var.project_name}-eks"
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true # showcase cluster; restrict CIDRs below for real prod use
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  # IRSA lets pods (like our AI service and ArgoCD) assume fine-grained IAM roles
  # instead of using node-wide credentials — a DevSecOps least-privilege pattern.
  enable_irsa = true

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy              = { most_recent = true }
    vpc-cni                 = { most_recent = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role = "general"
      }
    }
  }

  # CloudWatch control-plane logging — ties into the same observability
  # story as GuardDuty/Wazuh/CloudWatch used at Pay10.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Terraform = "true"
  }
}

# IRSA role the AI incident-assistant pod uses to call Bedrock / read Secrets Manager
module "ai_service_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.project_name}-svc-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ai-incident-assistant:ai-incident-assistant"]
    }
  }
}

resource "aws_iam_policy" "ai_service_permissions" {
  name        = "${var.project_name}-svc-policy"
  description = "Least-privilege permissions for the AI incident-assistant pod"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeBedrockModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/*"
      },
      {
        Sid      = "ReadServiceSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.project_name}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ai_service_attach" {
  role       = module.ai_service_irsa_role.iam_role_name
  policy_arn = aws_iam_policy.ai_service_permissions.arn
}
