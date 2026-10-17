module "backup_recovery" {
  count                    = var.db_profile == "dr" ? 1 : 0
  source                   = "../../modules/replicated-bucket"
  providers                = { aws = aws.dr }
  source_bucket_arn        = module.velero.bucket_arn
  source_kms_key_arn       = module.kms.key_arn
  destination_name         = "${local.name}-recovery-${data.aws_caller_identity.current.account_id}-${var.dr_region}"
  destination_kms_key_arn  = module.kms_dr[0].key_arn
  source_region            = var.aws_region
  destination_region       = var.dr_region
  account_id               = data.aws_caller_identity.current.account_id
  role_name                = "${local.name}-backup-replication"
  permissions_boundary_arn = local.permissions_boundary_arn
  depends_on               = [module.velero]
}
resource "aws_iam_role_policy" "velero_dr_recovery" {
  count = var.db_profile == "dr" ? 1 : 0
  name  = "read-only-primary-recovery"
  role  = "${local.name}-dr-velero"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = module.backup_recovery[0].bucket_arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${module.backup_recovery[0].bucket_arn}/*" }
    ]
  })
  depends_on = [module.velero_dr]
}
output "backup_recovery_bucket" {
  description = "Versioned cross-region S3 recovery copy; Velero DR has read access only."
  value       = var.db_profile == "dr" ? module.backup_recovery[0].bucket_name : ""
}
resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count               = var.db_profile == "dr" ? 1 : 0
  provider            = aws.dr
  alarm_name          = "${local.name}-dr-replica-lag"
  alarm_description   = "Replica lag >60s for 5 minutes. Check backup age and fence the primary before promotion."
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 60
  treat_missing_data  = "breaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.dr[0].identifier }
}
