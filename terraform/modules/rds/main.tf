# PostgreSQL 17 for dx01v2. The password is an ephemeral value sent only through write-only
# arguments (password_wo, secret_string_wo): it never reaches the Terraform plan or state.

locals {
  identifier = "${var.name}-postgres"
}

ephemeral "random_password" "db" {
  length  = 40
  special = false
}

resource "aws_db_subnet_group" "this" {
  name        = local.identifier
  description = "Private subnets of ${local.identifier}."
  subnet_ids  = var.subnet_ids
}

# name_prefix + create_before_destroy: a replacement never collides with the group still in use.
resource "aws_security_group" "this" {
  name_prefix = "${local.identifier}-"
  description = "PostgreSQL of ${var.name}: 5432 only from the allowed security groups, no egress."
  vpc_id      = var.vpc_id

  tags = {
    Name = local.identifier
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.key}"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-postgres17-"
  family      = "postgres17"
  description = "TLS-only connections and slow query logging for ${local.identifier}."

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    # Log statements slower than 1 s (exported to CloudWatch Logs).
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created before the instance so RDS log exports get retention and KMS encryption.
resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${local.identifier}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name             = var.db_name
  username            = var.username
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = var.password_version
  port                = 5432

  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.this.id]
  publicly_accessible                 = false
  network_type                        = "IPV4"
  parameter_group_name                = aws_db_parameter_group.this.name
  ca_cert_identifier                  = "rds-ca-rsa2048-g1"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  multi_az                    = var.multi_az
  backup_retention_period     = var.backup_retention_days
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = var.skip_final_snapshot
  final_snapshot_identifier   = var.skip_final_snapshot ? null : "${local.identifier}-final"
  copy_tags_to_snapshot       = true
  delete_automated_backups    = true
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = true

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/db/app"
  description             = "PostgreSQL credentials of dx01v2 (JSON: username, password, host, port, dbname)."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Write-only: Terraform sends it once per secret_string_wo_version and never stores it.
  secret_string_wo = jsonencode({
    username = var.username
    password = ephemeral.random_password.db.result
    host     = aws_db_instance.this.address
    port     = tostring(aws_db_instance.this.port)
    dbname   = var.db_name
  })
  secret_string_wo_version = var.password_version

  lifecycle {
    # A replaced instance gets a new password in the same apply; publish it with the new version.
    replace_triggered_by = [aws_db_instance.this.resource_id]
  }
}
