terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state bucket must already exist - Terraform doesn't create its own
  # backend. use_lockfile replaces the older DynamoDB-table locking approach.
  backend "s3" {
    bucket       = "max-devops-terraform-state-2026"
    key          = "project/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}