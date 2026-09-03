terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # Remote state — S3 + DynamoDB lock table.
  # Create these two resources manually once (or via a bootstrap TF root)
  # before running `terraform init` here, then uncomment.
  #
  # backend "s3" {
  #   bucket         = "sachinms-tfstate-devops-showcase"
  #   key            = "ai-incident-assistant/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "tf-locks-devops-showcase"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ai-incident-assistant"
      Owner       = "sachin-ms"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Configured after EKS is created so Helm/K8s providers can talk to the cluster
data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
