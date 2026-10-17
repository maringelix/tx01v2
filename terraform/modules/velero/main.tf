# The backup storage of Velero (profile full of platform/install.sh): an encrypted S3 bucket with a
# lifecycle, and the Pod Identity role of the service account velero/velero, limited to that bucket and
# the lab key. An empty bucket and a role cost nothing, so they exist whether or not the profile full is
# installed. Velero backs up the Kubernetes objects only (no volume snapshots: the lab keeps no state in
# the cluster), so the role has no EC2 permissions.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Same shape as the state bucket of the bootstrap. platform/install.sh derives this name from the
  # account and the region, so it needs no contract parameter.
  bucket_name = "${var.name}-velero-${local.account_id}-${local.region}"
}

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    # Kopia repository chunks are reference counted, not safe to expire by object age.
    filter { prefix = "backups/" }

    expiration {
      days = var.retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# --- Velero: velero/velero (EKS Pod Identity) ---

resource "aws_iam_role" "this" {
  name                 = "${var.name}-velero"
  description          = "Velero of ${var.name}: backs up the Kubernetes objects to its S3 bucket (EKS Pod Identity)."
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EksPodIdentityOfThisCluster"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = var.cluster_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name = "backups-bucket"
  role = aws_iam_role.this.id

  # The policy of the velero-plugin-for-aws without the EC2 snapshot statement, plus the lab key
  # (used through S3 only).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListTheBackupBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.this.arn
      },
      {
        Sid    = "ReadAndWriteBackups"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.this.arn}/*"
      },
      {
        Sid      = "EncryptWithTheLabKeyThroughS3Only"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = "velero"
  service_account = "velero"
  role_arn        = aws_iam_role.this.arn
}
