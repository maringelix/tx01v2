mock_provider "aws" {
  alias  = "dr"
  source = "../tests/mocks"
}

# Remote state bucket hardening.

mock_provider "aws" {
  source = "../tests/mocks"
}

variables {
  github_owner         = "maringelix"
  github_owner_id      = "1000000"
  tx01v2_repository_id = "2000000"
  dx01v2_repository_id = "3000000"
  budget_alert_emails  = ["lab-alerts@example.org"]
}

run "state_bucket_is_hardened" {
  command = apply

  assert {
    condition     = aws_s3_bucket.state.bucket == "tx01v2-tfstate-123456789012-us-east-1"
    error_message = "The bucket must be named <project>-tfstate-<account_id>-<region>."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "force_destroy must be off by default."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be enabled."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "All four public access block settings must be true."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "AES256"
    error_message = "Default encryption must be on."
  }

  assert {
    condition = jsondecode(aws_s3_bucket_policy.state.policy).Statement == [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1", "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
    error_message = "The bucket policy must deny every request that does not use TLS."
  }

  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.state.rule : r.noncurrent_version_expiration[0].noncurrent_days if length(r.noncurrent_version_expiration) > 0] == [90]
    error_message = "Noncurrent state versions must expire after 90 days."
  }

  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.state.rule : r.abort_incomplete_multipart_upload[0].days_after_initiation if length(r.abort_incomplete_multipart_upload) > 0] == [7]
    error_message = "Incomplete multipart uploads must be aborted after 7 days."
  }

  assert {
    condition     = output.backend_hcl == "bucket = \"tx01v2-tfstate-123456789012-us-east-1\"\nregion = \"us-east-1\"\n"
    error_message = "backend_hcl must be ready to paste into terraform/envs/lab/backend.hcl."
  }
}

run "force_destroy_is_an_explicit_choice" {
  command = plan

  variables {
    state_bucket_force_destroy = true
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy
    error_message = "state_bucket_force_destroy must reach the bucket."
  }
}
run "state_recovery_is_opt_in_versioned_and_remote" {
  command = apply
  variables { enable_state_dr = true }
  assert {
    condition     = output.state_recovery_bucket == "tx01v2-tfstate-dr-123456789012-us-west-2" && one(aws_s3_bucket_replication_configuration.state_recovery[0].rule).delete_marker_replication[0].status == "Disabled"
    error_message = "The enabled state recovery bucket must be in the selected second region."
  }
}
