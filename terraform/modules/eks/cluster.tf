# EKS control plane: API-only authentication (access entries, no aws-auth ConfigMap),
# standard support only (no extended-support surcharge), KMS envelope encryption of secrets
# and all control plane logs in a log group created before the cluster.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Built from the name instead of aws_eks_cluster.this.arn so trust policies are known at plan time.
  cluster_arn = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.name}"

  cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

resource "aws_cloudwatch_log_group" "cluster" {
  # EKS writes to exactly this name; creating it first gives retention and KMS encryption.
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.name}-cluster"
  description          = "EKS control plane role of ${var.name}."
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EksControlPlane"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy" "cluster_kms" {
  name = "secrets-envelope-encryption"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "UseTheLabKeyForKubernetesSecrets"
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = var.kms_key_arn
    }]
  })
}

resource "aws_eks_cluster" "this" {
  name                          = var.name
  version                       = var.cluster_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = false
  deletion_protection           = false
  enabled_cluster_log_types     = local.cluster_log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = var.kms_key_arn
    }
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    # Public endpoint restricted to var.endpoint_public_access_cidrs. GitHub-hosted runners need it
    # (see docs/ARQUITETURA.md); every request is still authenticated with IAM + access entries.
    endpoint_public_access = true
    public_access_cidrs    = var.endpoint_public_access_cidrs
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
  ]
}
