output "state_bucket_name" {
  description = "S3 bucket of the lab state."
  value       = aws_s3_bucket.state.bucket
}

output "backend_hcl" {
  description = "Ready content of terraform/envs/lab/backend.hcl (git-ignored)."
  value       = <<-EOT
    bucket = "${aws_s3_bucket.state.bucket}"
    region = "${local.region}"
  EOT
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider used by the trust policies."
  value       = local.github_oidc_provider_arn
}

output "plan_role_arn" {
  description = "Role for terraform-plan.yml (repository variable AWS_PLAN_ROLE_ARN of tx01v2)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for apply/platform/destroy (repository variable AWS_APPLY_ROLE_ARN of tx01v2)."
  value       = aws_iam_role.apply.arn
}

output "deploy_role_arn" {
  description = "Role for the dx01v2 deploy workflow; also goes into app_deployer_principal_arns of the lab."
  value       = aws_iam_role.deploy.arn
}

output "budget_name" {
  description = "AWS Budgets budget that sends the cost alerts."
  value       = aws_budgets_budget.monthly.name
}
