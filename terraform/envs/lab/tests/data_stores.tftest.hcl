# modules/rds and modules/ecr tested directly. The RDS runs prove that the database password
# never lands in the plan or the state: only write-only arguments and their versions are set.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  github_owner               = "maringelix"
  name                       = "tx01v2-lab"
  vpc_id                     = "vpc-0123456789abcdef0"
  subnet_ids                 = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
  allowed_security_group_ids = { eks_cluster = "sg-0123456789abcdef0" }
  kms_key_arn                = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  repository_names           = ["dx01v2/api", "dx01v2/web"]
}

run "rds_engine_storage_and_network" {
  command = apply

  module {
    source = "../../modules/rds"
  }

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17" && aws_db_instance.this.instance_class == "db.t4g.micro"
    error_message = "The database must be PostgreSQL 17 on db.t4g.micro."
  }

  assert {
    condition = (
      aws_db_instance.this.storage_encrypted &&
      aws_db_instance.this.kms_key_id == var.kms_key_arn &&
      aws_db_instance.this.storage_type == "gp3" &&
      aws_db_instance.this.allocated_storage == 20 &&
      aws_db_instance.this.max_allocated_storage == 50
    )
    error_message = "Storage must be gp3 20 GB (autoscaling to 50), encrypted with the lab key."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && aws_db_instance.this.vpc_security_group_ids == toset([aws_security_group.this.id])
    error_message = "The database must not be public and must use only its own security group."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.postgres) == 1 &&
      aws_vpc_security_group_ingress_rule.postgres["eks_cluster"].referenced_security_group_id == "sg-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.postgres["eks_cluster"].cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.postgres["eks_cluster"].from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.postgres["eks_cluster"].to_port == 5432
    )
    error_message = "Only 5432 from the given security groups may reach the database."
  }

  assert {
    condition = (
      aws_db_parameter_group.this.family == "postgres17" &&
      contains([for p in aws_db_parameter_group.this.parameter : "${p.name}=${p.value}"], "rds.force_ssl=1") &&
      contains([for p in aws_db_parameter_group.this.parameter : p.name], "log_min_duration_statement") &&
      aws_db_instance.this.parameter_group_name == aws_db_parameter_group.this.name
    )
    error_message = "A custom postgres17 parameter group must force TLS and log slow queries."
  }

  assert {
    condition = (
      aws_db_instance.this.iam_database_authentication_enabled &&
      aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1" &&
      aws_db_instance.this.enabled_cloudwatch_logs_exports == toset(["postgresql", "upgrade"])
    )
    error_message = "IAM auth, an explicit CA and log exports must be configured."
  }

  assert {
    condition = (
      aws_db_instance.this.multi_az == false &&
      aws_db_instance.this.backup_retention_period == 1 &&
      aws_db_instance.this.deletion_protection == false &&
      aws_db_instance.this.skip_final_snapshot &&
      aws_db_instance.this.final_snapshot_identifier == null
    )
    error_message = "Lab defaults: single-AZ, 1-day backups, destroyable without a final snapshot."
  }

  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.this : g.kms_key_id == var.kms_key_arn && startswith(g.name, "/aws/rds/instance/tx01v2-lab-postgres/")])
    error_message = "RDS log groups must be pre-created with KMS encryption."
  }
}

run "rds_password_never_in_plan_or_state" {
  command = apply

  module {
    source = "../../modules/rds"
  }

  assert {
    condition     = aws_db_instance.this.password == null && aws_db_instance.this.password_wo == null
    error_message = "No password may be stored for the DB instance."
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == 1 && aws_db_instance.this.manage_master_user_password == null
    error_message = "The password must be set only through password_wo (version 1)."
  }

  assert {
    condition = (
      aws_secretsmanager_secret.db.name == "tx01v2-lab/db/app" &&
      aws_secretsmanager_secret.db.kms_key_id == var.kms_key_arn &&
      aws_secretsmanager_secret.db.recovery_window_in_days == 0
    )
    error_message = "The DB secret must follow the contract name and use the lab key."
  }

  assert {
    condition = (
      aws_secretsmanager_secret_version.db.secret_string == null &&
      aws_secretsmanager_secret_version.db.secret_string_wo == null &&
      aws_secretsmanager_secret_version.db.secret_string_wo_version == 1
    )
    error_message = "The DB secret value must be written only through secret_string_wo."
  }
}

run "rds_password_rotation_bumps_both_versions" {
  command = plan

  module {
    source = "../../modules/rds"
  }

  variables {
    password_version = 2
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == 2 && aws_secretsmanager_secret_version.db.secret_string_wo_version == 2
    error_message = "password_version must rotate the DB password and the secret together."
  }
}

run "ecr_repositories" {
  command = apply

  module {
    source = "../../modules/ecr"
  }

  assert {
    condition     = toset(keys(aws_ecr_repository.this)) == toset(["dx01v2/api", "dx01v2/web"])
    error_message = "The contract repositories dx01v2/api and dx01v2/web must exist."
  }

  assert {
    condition = alltrue([
      for r in aws_ecr_repository.this :
      r.image_tag_mutability == "IMMUTABLE" &&
      r.image_scanning_configuration[0].scan_on_push &&
      r.encryption_configuration[0].encryption_type == "KMS" &&
      r.encryption_configuration[0].kms_key == var.kms_key_arn &&
      r.force_delete
    ])
    error_message = "Repositories must be IMMUTABLE, scanned on push, KMS-encrypted and force-deletable in the lab."
  }

  assert {
    condition = alltrue([
      for p in aws_ecr_lifecycle_policy.this :
      [for r in jsondecode(p.policy).rules : "${r.selection.tagStatus}:${r.selection.countType}:${r.selection.countNumber}"] == ["untagged:sinceImagePushed:1", "any:imageCountMoreThan:20"]
    ])
    error_message = "Lifecycle: expire untagged images after 1 day, keep the last 20."
  }
}
