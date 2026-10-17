module "state_recovery" {
  count              = var.enable_state_dr ? 1 : 0
  source             = "../modules/replicated-bucket"
  providers          = { aws = aws, aws.dr = aws.dr }
  source_bucket_id   = aws_s3_bucket.state.id
  source_bucket_arn  = aws_s3_bucket.state.arn
  destination_name   = "${local.project}-tfstate-dr-${local.account_id}-${var.dr_region}"
  source_region      = var.aws_region
  destination_region = var.dr_region
  account_id         = local.account_id
  role_name          = "tx01v2-bootstrap-state-replication"
  depends_on         = [aws_s3_bucket_versioning.state]
}
output "state_recovery_bucket" {
  description = "Cross-region recovery copies of versioned state (empty when disabled). Never use two live backends."
  value       = var.enable_state_dr ? module.state_recovery[0].bucket_name : ""
}
