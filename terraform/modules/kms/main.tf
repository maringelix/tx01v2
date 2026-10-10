# One customer managed key for the whole lab: EKS secrets envelope encryption, RDS storage,
# Secrets Manager, ECR and every CloudWatch log group (flow logs, EKS control plane, RDS, WAF).

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  key_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Delegates access control to IAM policies of this account (the default key policy).
        Sid       = "EnableIamPoliciesOfThisAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Logs encrypts log groups of this account and region only.
        Sid       = "AllowCloudWatchLogsOfThisAccountAndRegion"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.${local.dns_suffix}" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
    ]
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name}: EKS secrets, RDS, Secrets Manager, ECR and CloudWatch Logs"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = jsonencode(local.key_policy)

  tags = {
    Name = var.name
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
