mock_provider "aws" { source = "../../tests/mocks" }
mock_provider "aws" {
  alias  = "dr"
  source = "../../tests/mocks"
}
run "recovery_bucket_and_replication_are_scoped" {
  command = apply
  module { source = "../../modules/replicated-bucket" }
  variables {
    source_bucket_arn        = "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1"
    destination_name         = "tx01v2-lab-recovery-123456789012-us-west-2"
    source_kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    destination_kms_key_arn  = "arn:aws:kms:us-west-2:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    source_region            = "us-east-1"
    destination_region       = "us-west-2"
    account_id               = "123456789012"
    role_name                = "tx01v2-lab-backup-replication"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary"
  }
  assert {
    condition = (
      aws_s3_bucket.recovery.bucket == "tx01v2-lab-recovery-123456789012-us-west-2" &&
      aws_s3_bucket.recovery.force_destroy == false &&
      aws_s3_bucket_public_access_block.recovery.block_public_policy &&
      aws_s3_bucket_versioning.recovery.versioning_configuration[0].status == "Enabled" &&
      aws_iam_role.replication.permissions_boundary == var.permissions_boundary_arn
    )
    error_message = "Recovery must survive deletion, keep versions and not replicate delete markers."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.replication.policy).Statement[0].Resource == var.source_bucket_arn &&
      jsondecode(aws_iam_role_policy.replication.policy).Statement[2].Resource == "${aws_s3_bucket.recovery.arn}/*" &&
      one(aws_s3_bucket_server_side_encryption_configuration.recovery.rule).apply_server_side_encryption_by_default[0].kms_master_key_id == var.destination_kms_key_arn
    )
    error_message = "Only the named source and regional encrypted recovery destination may be accessed."
  }
}
