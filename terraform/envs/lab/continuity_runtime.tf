# Opt-in independent regional runtime. No shared VPC, cluster, regional key or registry.
module "kms_dr" {
  count     = var.db_profile == "dr" ? 1 : 0
  providers = { aws = aws.dr }
  source    = "../../modules/kms"

  name                    = "${local.name}-dr"
  deletion_window_in_days = var.kms_deletion_window_days
}

module "network_dr" {
  count     = var.db_profile == "dr" ? 1 : 0
  providers = { aws = aws.dr }
  source    = "../../modules/network"

  name                     = "${local.name}-dr"
  permissions_boundary_arn = local.permissions_boundary_arn
  vpc_cidr                 = var.dr_vpc_cidr
  az_count                 = var.az_count
  nat_gateway_per_az       = var.nat_gateway_per_az
  flow_logs_retention_days = var.log_retention_days
  kms_key_arn              = module.kms_dr[0].key_arn
}

module "eks_dr" {
  count               = var.db_profile == "dr" ? 1 : 0
  providers           = { aws = aws.dr }
  source              = "../../modules/eks"
  secrets_name_prefix = local.name

  name                         = "${local.name}-dr"
  permissions_boundary_arn     = local.permissions_boundary_arn
  cluster_version              = var.cluster_version
  private_subnet_ids           = module.network_dr[0].private_subnet_ids
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  kms_key_arn                  = module.kms_dr[0].key_arn
  log_retention_days           = var.log_retention_days
  enable_spot_pool             = var.enable_spot_pool
  node_capacity_type           = var.node_capacity_type
  node_instance_types          = var.node_instance_types
  node_desired_size            = var.node_desired_size
  node_min_size                = var.node_min_size
  node_max_size                = var.node_max_size
  node_disk_size_gb            = var.node_disk_size_gb
  cluster_admin_principal_arns = var.cluster_admin_principal_arns
  app_deployer_principal_arns  = var.app_deployer_principal_arns
  tags                         = local.default_tags
}

module "ecr_dr" {
  count     = var.db_profile == "dr" ? 1 : 0
  providers = { aws = aws.dr }
  source    = "../../modules/ecr"

  repository_names = toset(local.ecr_repositories)
  kms_key_arn      = module.kms_dr[0].key_arn
  force_delete     = var.ecr_force_delete
}

module "velero_dr" {
  count         = var.db_profile == "dr" ? 1 : 0
  providers     = { aws = aws.dr }
  force_destroy = false
  source        = "../../modules/velero"

  name                     = "${local.name}-dr"
  cluster_name             = module.eks_dr[0].cluster_name
  cluster_arn              = module.eks_dr[0].cluster_arn
  kms_key_arn              = module.kms_dr[0].key_arn
  permissions_boundary_arn = local.permissions_boundary_arn
}

module "waf_dr" {
  count     = var.db_profile == "dr" ? 1 : 0
  providers = { aws = aws.dr }
  source    = "../../modules/waf"

  name               = "${local.name}-dr"
  rate_limit         = var.waf_rate_limit
  log_retention_days = var.log_retention_days
  kms_key_arn        = module.kms_dr[0].key_arn
}
