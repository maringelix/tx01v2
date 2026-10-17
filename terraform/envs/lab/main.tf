# Lab root: composes the modules for the tx01v2-lab environment. Names, tags and published
# values follow docs/CONTRATO.md (the contract with dx01v2). Nothing in Terraform talks to the
# Kubernetes API: controllers and manifests are installed by platform/install.sh.

locals {
  project     = "tx01v2"
  environment = "lab"
  name        = "${local.project}-${local.environment}"

  db_ha                    = contains(["ha", "dr"], var.db_profile)
  db_backup_retention_days = local.db_ha ? max(7, var.db_backup_retention_days) : var.db_backup_retention_days

  default_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Repository  = "${var.github_owner}/tx01v2"
  }

  ecr_repositories = ["dx01v2/api", "dx01v2/web"]

  # Created by the bootstrap (terraform/bootstrap/boundary.tf). The apply role can create a role of
  # the lab only with it, so every role below carries it.
  permissions_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.project}-lab-boundary"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

module "kms" {
  source = "../../modules/kms"

  name                    = local.name
  deletion_window_in_days = var.kms_deletion_window_days
}

module "network" {
  source = "../../modules/network"

  name                     = local.name
  permissions_boundary_arn = local.permissions_boundary_arn
  vpc_cidr                 = var.vpc_cidr
  az_count                 = var.az_count
  nat_gateway_per_az       = var.nat_gateway_per_az
  flow_logs_retention_days = var.log_retention_days
  kms_key_arn              = module.kms.key_arn
}

module "eks" {
  source = "../../modules/eks"

  name                         = local.name
  permissions_boundary_arn     = local.permissions_boundary_arn
  cluster_version              = var.cluster_version
  private_subnet_ids           = module.network.private_subnet_ids
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  kms_key_arn                  = module.kms.key_arn
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

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
  # Nodes (and therefore pods) use the EKS cluster security group.
  allowed_security_group_ids  = { eks_cluster = module.eks.cluster_security_group_id }
  kms_key_arn                 = module.kms.key_arn
  instance_class              = var.db_instance_class
  allocated_storage_gb        = var.db_allocated_storage_gb
  max_allocated_storage_gb    = var.db_max_allocated_storage_gb
  multi_az                    = local.db_ha || var.db_multi_az
  backup_retention_days       = local.db_backup_retention_days
  deletion_protection         = var.db_deletion_protection
  skip_final_snapshot         = var.db_skip_final_snapshot
  delete_automated_backups    = var.db_delete_automated_backups
  password_version            = var.db_password_version
  secret_recovery_window_days = var.secret_recovery_window_days
  log_retention_days          = var.log_retention_days
  # Native replication preserves the CURRENT stored credential without a read in the plan or
  # regenerating an unrelated ephemeral value when DR is enabled on an existing primary.
  secret_replica_keys = var.db_profile == "dr" ? { (var.dr_region) = module.kms_dr[0].key_arn } : {}
}

module "ecr" {
  source = "../../modules/ecr"

  repository_names = toset(local.ecr_repositories)
  kms_key_arn      = module.kms.key_arn
  force_delete     = var.ecr_force_delete
}

module "velero" {
  source = "../../modules/velero"

  name                     = local.name
  cluster_name             = module.eks.cluster_name
  cluster_arn              = module.eks.cluster_arn
  kms_key_arn              = module.kms.key_arn
  permissions_boundary_arn = local.permissions_boundary_arn
}

module "waf" {
  source = "../../modules/waf"

  name               = local.name
  rate_limit         = var.waf_rate_limit
  log_retention_days = var.log_retention_days
  kms_key_arn        = module.kms.key_arn
}
