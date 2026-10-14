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

output "github_variables_tx01v2" {
  description = "Repository variables of tx01v2 known after the bootstrap (docs/RUNBOOK.md lists the other LAB_* ones you choose; add your own admin role to LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS)."
  value = {
    AWS_REGION                       = local.region
    TF_STATE_BUCKET                  = aws_s3_bucket.state.bucket
    AWS_PLAN_ROLE_ARN                = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN               = aws_iam_role.apply.arn
    LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS = jsonencode([aws_iam_role.apply.arn])
    LAB_APP_DEPLOYER_PRINCIPAL_ARNS  = jsonencode([aws_iam_role.deploy.arn])
  }
}

output "github_variables_dx01v2" {
  description = "Repository variables of dx01v2 (its deploy workflow)."
  value = {
    AWS_REGION          = local.region
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.deploy.arn
  }
}
