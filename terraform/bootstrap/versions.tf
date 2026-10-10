terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # Local state on purpose: this root creates the state bucket itself. Keep terraform.tfstate
  # (git-ignored) safe, or migrate it into the bucket afterwards (docs/RUNBOOK.md).
}
