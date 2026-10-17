locals {
  dr_contract_parameters = var.db_profile == "dr" ? merge(local.contract_parameters, {
    "region"          = var.dr_region
    "cluster-name"    = module.eks_dr[0].cluster_name
    "vpc-id"          = module.network_dr[0].vpc_id
    "vpc-cidr"        = module.network_dr[0].vpc_cidr
    "alb/source-cidr" = module.network_dr[0].alb_source_cidr
    "ecr/api-url"     = module.ecr_dr[0].repository_urls["dx01v2/api"]
    "ecr/web-url"     = module.ecr_dr[0].repository_urls["dx01v2/web"]
    "waf/acl-arn"     = module.waf_dr[0].web_acl_arn
    # Native replicas retain the names of their source secrets in the SECONDARY region.
    "db/secret-name"              = module.rds.secret_name
    "db/endpoint"                 = aws_db_instance.dr[0].address
    "app/admin-token-secret-name" = aws_secretsmanager_secret.admin_token.name
    "dns/acm-certificate-arn"     = local.dns_enabled ? aws_acm_certificate_validation.app_dr[0].certificate_arn : "disabled"
  }) : {}
}

resource "aws_ssm_parameter" "contract_dr" {
  for_each = local.dr_contract_parameters
  provider = aws.dr

  name           = "/${local.project}/lab-dr/${each.key}"
  description    = "tx01v2 -> dx01v2 regional recovery contract v7."
  type           = "String"
  tier           = "Standard"
  insecure_value = each.value
}

output "dr_cluster_name" {
  description = "Independent regional EKS cluster, empty without DR."
  value       = var.db_profile == "dr" ? module.eks_dr[0].cluster_name : ""
}

output "dr_database_identifier" {
  description = "Read replica that may be promoted only after operator fencing and lag review."
  value       = var.db_profile == "dr" ? aws_db_instance.dr[0].identifier : ""
}

output "dr_contract_prefix" {
  description = "SSM prefix to select after an authorized DR promotion."
  value       = var.db_profile == "dr" ? "/${local.project}/lab-dr" : ""
}

output "dr_velero_bucket" {
  description = "Independent S3 backup bucket in the recovery region."
  value       = var.db_profile == "dr" ? module.velero_dr[0].bucket_name : ""
}
