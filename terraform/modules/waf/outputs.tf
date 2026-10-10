output "web_acl_arn" {
  description = "ARN of the REGIONAL web ACL (published in SSM as /tx01v2/lab/waf/acl-arn)."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_name" {
  description = "Name of the web ACL."
  value       = aws_wafv2_web_acl.this.name
}

output "log_group_name" {
  description = "CloudWatch log group of the WAF logs."
  value       = aws_cloudwatch_log_group.waf.name
}
