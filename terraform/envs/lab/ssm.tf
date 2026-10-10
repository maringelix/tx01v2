# Cross-repo contract: values dx01v2 and platform/install.sh read at deploy time
# (docs/CONTRATO.md, prefix /tx01v2/lab/). None of them is a secret.

locals {
  ssm_prefix = "/${local.project}/${local.environment}"

  contract_parameters = {
    "region"                      = var.aws_region
    "cluster-name"                = module.eks.cluster_name
    "vpc-id"                      = module.network.vpc_id
    "vpc-cidr"                    = module.network.vpc_cidr
    "ecr/api-url"                 = module.ecr.repository_urls["dx01v2/api"]
    "ecr/web-url"                 = module.ecr.repository_urls["dx01v2/web"]
    "waf/acl-arn"                 = module.waf.web_acl_arn
    "db/secret-name"              = module.rds.secret_name
    "app/admin-token-secret-name" = aws_secretsmanager_secret.admin_token.name
    "eso/cluster-secret-store"    = "aws-secrets-manager"
  }
}

resource "aws_ssm_parameter" "contract" {
  for_each = local.contract_parameters

  name        = "${local.ssm_prefix}/${each.key}"
  description = "tx01v2 -> dx01v2 contract v1 (docs/CONTRATO.md)."
  type        = "String"
  tier        = "Standard"
  # Not secret: insecure_value keeps the value readable in plans.
  insecure_value = each.value
}
