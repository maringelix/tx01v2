output "bucket_name" {
  description = "Name of the backup bucket (platform/install.sh derives the same name for the BackupStorageLocation)."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "ARN of the backup bucket."
  value       = aws_s3_bucket.this.arn
}

output "role_arn" {
  description = "Pod Identity role of velero/velero."
  value       = aws_iam_role.this.arn
}
