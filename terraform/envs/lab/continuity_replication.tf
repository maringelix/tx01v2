# Replication configuration belongs to the SOURCE region; the destination module uses aws.dr only.
resource "aws_s3_bucket_replication_configuration" "backup_recovery" {
  count      = var.db_profile == "dr" ? 1 : 0
  bucket     = module.velero.bucket_name
  role       = module.backup_recovery[0].replication_role_arn
  depends_on = [module.velero, module.backup_recovery]
  rule {
    id     = "regional-recovery"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }
    destination {
      bucket        = module.backup_recovery[0].bucket_arn
      storage_class = "STANDARD"
      encryption_configuration { replica_kms_key_id = module.kms_dr[0].key_arn }
    }
  }
}
