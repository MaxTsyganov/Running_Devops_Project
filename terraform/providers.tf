terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  backend "s3" {
    bucket       = "max-devops-terraform-state-2026" # Keep your exact bucket name
    key          = "project/terraform.tfstate"
    region       = "us-east-1" # Keep your region
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}