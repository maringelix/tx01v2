# R9 pilot-light data copy. The destination key and replicated RDS backups exist only in the
# opt-in DR profile. An automated backup copy is not a running standby database: recovery requires
# an explicit restore and endpoint switch, described in docs/CONTINUITY.md.
resource "aws_kms_key" "dr_rds_backups" {
  count    = var.db_profile == "dr" ? 1 : 0
  provider = aws.dr

  description             = "tx01v2-lab replicated PostgreSQL backups in ${var.dr_region}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_db_instance_automated_backups_replication" "dr" {
  count    = var.db_profile == "dr" ? 1 : 0
  provider = aws.dr

  source_db_instance_arn = module.rds.arn
  kms_key_id             = aws_kms_key.dr_rds_backups[0].arn
  retention_period       = local.db_backup_retention_days
}
