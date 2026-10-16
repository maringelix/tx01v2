# Non-sensitive outputs only. Secrets stay in Secrets Manager (write-only), never in outputs.

output "region" {
  description = "AWS region of the lab."
  value       = var.aws_region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "update_kubeconfig_command" {
  description = "Command that writes the kubeconfig of the cluster to its own file (needs a principal with an access entry); ~/.kube/config and its current context stay untouched. Then: export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --kubeconfig ~/.kube/tx01v2-lab.kubeconfig"
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by name."
  value       = module.ecr.repository_urls
}

output "waf_web_acl_arn" {
  description = "WAF web ACL ARN for the app Ingress annotation."
  value       = module.waf.web_acl_arn
}

output "db_address" {
  description = "Private hostname of the PostgreSQL instance."
  value       = module.rds.address
}

output "db_secret_name" {
  description = "Secrets Manager secret with the database credentials."
  value       = module.rds.secret_name
}

output "admin_token_secret_name" {
  description = "Secrets Manager secret with the dx01v2 admin token."
  value       = aws_secretsmanager_secret.admin_token.name
}

output "ssm_parameter_names" {
  description = "Contract SSM parameters written by this root."
  value       = sort([for p in aws_ssm_parameter.contract : p.name])
}

output "velero_bucket_name" {
  description = "S3 bucket of the Velero backups (the profile full of platform/install.sh); platform/install.sh derives the same name."
  value       = module.velero.bucket_name
}

output "load_balancer_controller_role_arn" {
  description = "Pod Identity role of the AWS Load Balancer Controller."
  value       = module.eks.load_balancer_controller_role_arn
}

output "external_secrets_role_arn" {
  description = "Pod Identity role of External Secrets Operator."
  value       = module.eks.external_secrets_role_arn
}
