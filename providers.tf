terraform {
  # 1.11+ required: the S3 backend uses native lockfile locking (use_lockfile).
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.25.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cost-detective-audit"
      ManagedBy = "terraform"
    }
  }
}
