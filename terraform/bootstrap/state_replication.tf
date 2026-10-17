# Source-region API; the destination and service role use the separate DR provider.
resource "aws_s3_bucket_replication_configuration" "state_recovery" {
  count      = var.enable_state_dr ? 1 : 0
  bucket     = aws_s3_bucket.state.id
  role       = module.state_recovery[0].replication_role_arn
  depends_on = [aws_s3_bucket_versioning.state, module.state_recovery]
  rule {
    id     = "regional-state-recovery"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    destination {
      bucket        = module.state_recovery[0].bucket_arn
      storage_class = "STANDARD"
    }
  }
}
