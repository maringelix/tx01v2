# Cross-region, versioned recovery copy. The replication service role can read one source and
# replicate into one destination; deletion markers are not propagated.
resource "aws_s3_bucket" "recovery" {
  provider      = aws.dr
  bucket        = var.destination_name
  force_destroy = false
}
resource "aws_s3_bucket_public_access_block" "recovery" {
  provider                = aws.dr
  bucket                  = aws_s3_bucket.recovery.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "recovery" {
  provider = aws.dr
  bucket   = aws_s3_bucket.recovery.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "recovery" {
  provider = aws.dr
  bucket   = aws_s3_bucket.recovery.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "recovery" {
  provider = aws.dr
  bucket   = aws_s3_bucket.recovery.id
  rule {
    bucket_key_enabled = var.destination_kms_key_arn != null
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.destination_kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.destination_kms_key_arn
    }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "recovery" {
  provider   = aws.dr
  bucket     = aws_s3_bucket.recovery.id
  depends_on = [aws_s3_bucket_versioning.recovery]
  rule {
    id     = "expire-noncurrent-recovery-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
resource "aws_s3_bucket_policy" "recovery" {
  provider = aws.dr
  bucket   = aws_s3_bucket.recovery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [aws_s3_bucket.recovery.arn, "${aws_s3_bucket.recovery.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.recovery]
}
resource "aws_iam_role" "replication" {
  name                 = var.role_name
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sts:AssumeRole"
      # S3's documented service trust plus exact source/destination data permissions below.
      # If the service supplies SourceAccount, it must match; absence does not break replication.
      Condition = { StringEqualsIfExists = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}
resource "aws_iam_role_policy" "replication" {
  name = "one-source-one-recovery-bucket"
  role = aws_iam_role.replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadSourceConfiguration", Effect = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = var.source_bucket_arn
      },
      {
        Sid      = "ReadSourceVersions", Effect = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${var.source_bucket_arn}/*"
      },
      {
        Sid      = "ReplicateOnlyToRecovery", Effect = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateTags"]
        Resource = "${aws_s3_bucket.recovery.arn}/*"
      }
      ], var.source_kms_key_arn == null ? [] : [
      {
        Sid       = "DecryptOnlySource", Effect = "Allow", Action = ["kms:Decrypt"]
        Resource  = var.source_kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.source_region}.amazonaws.com" } }
      },
      {
        Sid       = "EncryptOnlyDestination", Effect = "Allow"
        Action    = ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = var.destination_kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.destination_region}.amazonaws.com" } }
      }
    ])
  })
}
resource "aws_s3_bucket_replication_configuration" "this" {
  bucket     = var.source_bucket_id
  role       = aws_iam_role.replication.arn
  depends_on = [aws_iam_role_policy.replication, aws_s3_bucket_versioning.recovery]
  rule {
    id     = "regional-recovery"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    dynamic "source_selection_criteria" {
      for_each = var.source_kms_key_arn == null ? [] : [1]
      content {
        sse_kms_encrypted_objects { status = "Enabled" }
      }
    }
    destination {
      bucket        = aws_s3_bucket.recovery.arn
      storage_class = "STANDARD"
      dynamic "encryption_configuration" {
        for_each = var.destination_kms_key_arn == null ? [] : [1]
        content { replica_kms_key_id = var.destination_kms_key_arn }
      }
    }
  }
}
output "bucket_name" { value = aws_s3_bucket.recovery.bucket }
output "bucket_arn" { value = aws_s3_bucket.recovery.arn }
output "replication_role_arn" { value = aws_iam_role.replication.arn }
