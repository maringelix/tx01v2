terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # bucket and region come from -backend-config (backend.hcl, see backend.hcl.example).
  # use_lockfile = S3 native locking: no DynamoDB table.
  backend "s3" {
    key          = "lab/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
