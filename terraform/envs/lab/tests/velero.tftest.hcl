# modules/velero tested directly: the backup bucket (name, encryption, lifecycle, TLS only) and the Pod
# Identity role of velero/velero, limited to that bucket and the lab key. The last run checks the wiring in
# the lab root.

mock_provider "aws" {
  source = "../../tests/mocks"
}

mock_provider "aws" {
  alias  = "dr"
  source = "../../tests/mocks"
}

variables {
  github_owner                 = "maringelix"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
  name                         = "tx01v2-lab"
  cluster_name                 = "tx01v2-lab"
  cluster_arn                  = "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab"
  kms_key_arn                  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  permissions_boundary_arn     = "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary"
}

run "the_bucket_is_private_encrypted_and_expires" {
  command = apply

  module {
    source = "../../modules/velero"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "tx01v2-lab-velero-123456789012-us-east-1" && aws_s3_bucket.this.force_destroy
    error_message = "The bucket must be <name>-velero-<account id>-<region> (platform/install.sh derives it) and must not block terraform destroy."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this.block_public_acls &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      aws_s3_bucket_public_access_block.this.ignore_public_acls &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets &&
      aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    )
    error_message = "The bucket must block every kind of public access and have ACLs disabled."
  }

  assert {
    condition = (
      one([for r in aws_s3_bucket_server_side_encryption_configuration.this.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "aws:kms" &&
      one([for r in aws_s3_bucket_server_side_encryption_configuration.this.rule : one(r.apply_server_side_encryption_by_default).kms_master_key_id]) == var.kms_key_arn &&
      one([for r in aws_s3_bucket_server_side_encryption_configuration.this.rule : r.bucket_key_enabled])
    )
    error_message = "The backups must be encrypted with the lab KMS key (bucket key on, to keep the KMS requests down)."
  }

  assert {
    condition = (
      length(aws_s3_bucket_lifecycle_configuration.this.rule) == 2 &&
      one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : one(r.expiration).days if r.id == "expire-backups"]) == 35 &&
      one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : one(r.abort_incomplete_multipart_upload).days_after_initiation if r.id == "abort-incomplete-multipart-uploads"]) == 7 &&
      alltrue([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.status == "Enabled"])
    )
    error_message = "Backups must expire after 35 days (above the 30-day TTL of a Velero backup) and incomplete uploads after 7."
  }

  assert {
    condition = jsondecode(aws_s3_bucket_policy.this.policy).Statement == [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
    error_message = "The bucket must refuse requests that do not use TLS."
  }
}

run "the_retention_follows_the_variable" {
  command = plan

  module {
    source = "../../modules/velero"
  }

  variables {
    retention_days = 45
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : one(r.expiration).days if r.id == "expire-backups"]) == 45
    error_message = "retention_days must set the expiration of the backups."
  }
}

run "the_role_reaches_only_the_bucket_and_the_key" {
  command = apply

  module {
    source = "../../modules/velero"
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement == [{
      Sid       = "EksPodIdentityOfThisCluster"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = "123456789012" }
        ArnEquals    = { "aws:SourceArn" = "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab" }
      }
    }]
    error_message = "The role must trust Pod Identity of this account and this cluster only."
  }

  assert {
    condition     = aws_iam_role.this.name == "tx01v2-lab-velero" && aws_iam_role.this.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must be named tx01v2-* (the apply role manages only those) and carry the permissions boundary of the lab (SEC-11)."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.this.policy).Statement == [
      {
        Sid      = "ListTheBackupBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.this.arn
      },
      {
        Sid      = "ReadAndWriteBackups"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:PutObjectTagging", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${aws_s3_bucket.this.arn}/*"
      },
      {
        Sid       = "EncryptWithTheLabKeyThroughS3Only"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
        Condition = { StringEquals = { "kms:ViaService" = "s3.us-east-1.amazonaws.com" } }
      },
    ]
    error_message = "Velero may use only its bucket and the lab key through S3: no volume snapshots (no EC2), no wildcard."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.this.cluster_name == "tx01v2-lab" &&
      aws_eks_pod_identity_association.this.namespace == "velero" &&
      aws_eks_pod_identity_association.this.service_account == "velero" &&
      aws_eks_pod_identity_association.this.role_arn == aws_iam_role.this.arn
    )
    error_message = "The Pod Identity association must bind the service account velero/velero (platform/values/full/velero.yaml) to the role."
  }
}

run "the_lab_root_creates_the_bucket_and_the_role" {
  command = plan

  assert {
    condition     = module.velero.bucket_name == "tx01v2-lab-velero-123456789012-us-east-1" && output.velero_bucket_name == module.velero.bucket_name
    error_message = "The lab root must create the Velero bucket and publish its name."
  }
}
