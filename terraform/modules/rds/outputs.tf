output "identifier" {
  description = "DB instance identifier."
  value       = aws_db_instance.this.identifier
}

output "arn" {
  description = "ARN of the source RDS instance for cross-Region automated backup replication."
  value       = aws_db_instance.this.arn
}

output "continuity_settings" {
  description = "Non-secret RDS recovery settings for plans, tests and the operator."
  value = {
    multi_az                 = aws_db_instance.this.multi_az
    backup_retention_days    = aws_db_instance.this.backup_retention_period
    deletion_protection      = aws_db_instance.this.deletion_protection
    skip_final_snapshot      = aws_db_instance.this.skip_final_snapshot
    delete_automated_backups = aws_db_instance.this.delete_automated_backups
  }
}

output "address" {
  description = "DB hostname (private; resolvable inside the VPC)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "DB port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "Security group of the DB instance."
  value       = aws_security_group.this.id
}

output "secret_arn" {
  description = "ARN of the credentials secret."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the credentials secret (contract: tx01v2-lab/db/app)."
  value       = aws_secretsmanager_secret.db.name
}
