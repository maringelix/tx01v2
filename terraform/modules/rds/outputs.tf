output "identifier" {
  description = "DB instance identifier."
  value       = aws_db_instance.this.identifier
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
