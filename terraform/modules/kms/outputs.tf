output "key_arn" {
  description = "ARN of the lab customer managed key."
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "ID of the lab customer managed key."
  value       = aws_kms_key.this.key_id
}

output "alias_name" {
  description = "Alias of the lab key (alias/<name>)."
  value       = aws_kms_alias.this.name
}
