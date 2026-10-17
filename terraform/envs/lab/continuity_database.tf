# The standby is asynchronous. It stays read-only until an operator proves fencing and promotes it.
# Multi-AZ protects the primary Region; this separate VPC/database protects the regional boundary.
resource "aws_db_subnet_group" "dr" {
  count       = var.db_profile == "dr" ? 1 : 0
  provider    = aws.dr
  name        = "${local.name}-dr-postgres"
  description = "Private subnets of the regional PostgreSQL recovery instance."
  subnet_ids  = module.network_dr[0].private_subnet_ids
}

resource "aws_security_group" "db_dr" {
  count       = var.db_profile == "dr" ? 1 : 0
  provider    = aws.dr
  name_prefix = "${local.name}-dr-postgres-"
  description = "DR PostgreSQL: only the independent secondary cluster may connect."
  vpc_id      = module.network_dr[0].vpc_id
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_dr" {
  count                        = var.db_profile == "dr" ? 1 : 0
  provider                     = aws.dr
  security_group_id            = aws_security_group.db_dr[0].id
  referenced_security_group_id = module.eks_dr[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from the DR EKS cluster"
}

resource "aws_db_parameter_group" "dr" {
  count       = var.db_profile == "dr" ? 1 : 0
  provider    = aws.dr
  name_prefix = "${local.name}-dr-postgres17-"
  family      = "postgres17"
  description = "TLS-only regional PostgreSQL replica"
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "pending-reboot"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "db_dr" {
  for_each          = var.db_profile == "dr" ? toset(["postgresql", "upgrade"]) : toset([])
  provider          = aws.dr
  name              = "/aws/rds/instance/${local.name}-dr-postgres/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = module.kms_dr[0].key_arn
}

resource "aws_db_instance" "dr" {
  count    = var.db_profile == "dr" ? 1 : 0
  provider = aws.dr

  identifier          = "${local.name}-dr-postgres"
  replicate_source_db = module.rds.arn
  instance_class      = var.db_instance_class
  storage_encrypted   = true
  storage_type        = "gp3"
  kms_key_id          = module.kms_dr[0].key_arn
  # Credentials and the database are inherited from the source, not sent in CreateDBInstanceReadReplica.
  publicly_accessible                 = false
  db_subnet_group_name                = aws_db_subnet_group.dr[0].name
  vpc_security_group_ids              = [aws_security_group.db_dr[0].id]
  parameter_group_name                = aws_db_parameter_group.dr[0].name
  ca_cert_identifier                  = "rds-ca-rsa2048-g1"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  backup_retention_period             = local.db_backup_retention_days
  deletion_protection                 = var.db_deletion_protection
  skip_final_snapshot                 = var.db_skip_final_snapshot
  final_snapshot_identifier           = var.db_skip_final_snapshot ? null : "${local.name}-dr-postgres-final"
  delete_automated_backups            = var.db_delete_automated_backups
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false
  apply_immediately                   = true
  depends_on                          = [aws_cloudwatch_log_group.db_dr]
}

# Current credentials are copied by native Secrets Manager replication. The DR contract overrides only the public DB endpoint.
