terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same state bucket as the environment, different key:
  # terraform init -backend-config=../backend.hcl -backend-config="key=medibook/bootstrap/terraform.tfstate"
  backend "s3" {}
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project    = var.project
      Stack      = "bootstrap"
      ManagedBy  = "terraform"
      Repository = "github.com/${var.github_repository}"
    }
  }
}
