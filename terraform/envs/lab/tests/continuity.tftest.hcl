mock_provider "aws" {
  source = "../../tests/mocks"
}

mock_provider "aws" {
  alias  = "dr"
  source = "../../tests/mocks"
  mock_data "aws_region" {
    defaults = {
      region      = "us-west-2"
      description = "US West (Oregon)"
      endpoint    = "ec2.us-west-2.amazonaws.com"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-west-2a", "us-west-2b", "us-west-2c"]
      zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-west-2:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
      key_id = "1234abcd-12ab-34cd-56ef-1234567890ab"
    }
  }
}

variables {
  github_owner                 = "maringelix"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
}

run "core_does_not_create_a_second_region_backup" {
  command = plan

  assert {
    condition = (
      output.db_continuity_profile == "core" &&
      output.db_continuity_settings.multi_az == false &&
      output.db_continuity_settings.backup_retention_days == 1 &&
      output.db_continuity_settings.delete_automated_backups &&
      output.dr_region == "disabled" &&
      length(aws_kms_key.dr_rds_backups) == 0 &&
      length(aws_db_instance_automated_backups_replication.dr) == 0
    )
    error_message = "Core must keep the cheap single-Region defaults."
  }
}

run "ha_enables_multiaz_and_pitr_without_second_region" {
  command = plan

  variables {
    db_profile = "ha"
  }

  assert {
    condition     = local.db_ha && output.db_continuity_settings.multi_az && output.db_continuity_settings.backup_retention_days == 7 && length(aws_db_instance_automated_backups_replication.dr) == 0
    error_message = "HA must enable at least seven days of PITR without cross-Region replication."
  }
}

run "dr_uses_a_different_region_and_destination_key" {
  command = apply

  variables {
    db_profile = "dr"
    dr_region  = "us-west-2"
  }

  assert {
    condition = (
      output.dr_region == "us-west-2" &&
      output.db_continuity_settings.multi_az &&
      output.db_continuity_settings.backup_retention_days == 7 &&
      length(aws_kms_key.dr_rds_backups) == 1 &&
      aws_kms_key.dr_rds_backups[0].enable_key_rotation &&
      length(aws_db_instance_automated_backups_replication.dr) == 1 &&
      aws_db_instance_automated_backups_replication.dr[0].source_db_instance_arn == module.rds.arn &&
      aws_db_instance_automated_backups_replication.dr[0].kms_key_id == aws_kms_key.dr_rds_backups[0].arn &&
      aws_db_instance_automated_backups_replication.dr[0].retention_period == 7
    )
    error_message = "DR must replicate encrypted automated backups to a distinct destination Region."
  }
}

run "dr_refuses_the_primary_region" {
  command = plan

  variables {
    db_profile = "dr"
    dr_region  = "us-east-1"
  }

  expect_failures = [var.dr_region]
}

run "unknown_profile_is_rejected" {
  command = plan

  variables {
    db_profile = "active-active"
  }

  expect_failures = [var.db_profile]
}

run "dr_has_a_private_independent_runtime_and_current_credentials" {
  command = apply
  variables {
    db_profile = "dr"
  }
  assert {
    condition = (
      module.eks_dr[0].cluster_name == "tx01v2-lab-dr" &&
      module.rds.secret_replica_regions == ["us-west-2"] &&
      module.network_dr[0].vpc_cidr == "10.10.0.0/16" &&
      aws_db_instance.dr[0].replicate_source_db == module.rds.arn &&
      aws_db_instance.dr[0].kms_key_id == module.kms_dr[0].key_arn &&
      !aws_db_instance.dr[0].publicly_accessible &&
      aws_db_instance.dr[0].backup_retention_period >= 7 &&
      aws_vpc_security_group_ingress_rule.db_dr[0].referenced_security_group_id == module.eks_dr[0].cluster_security_group_id &&
      length(aws_ssm_parameter.contract_dr) == 16 &&
      aws_ssm_parameter.contract_dr["region"].insecure_value == "us-west-2" &&
      aws_ssm_parameter.contract_dr["db/endpoint"].insecure_value == aws_db_instance.dr[0].address &&
      aws_ssm_parameter.contract_dr["db/secret-name"].insecure_value == module.rds.secret_name &&
      module.velero_dr[0].bucket_name == "tx01v2-lab-dr-velero-123456789012-us-west-2" &&
      output.backup_recovery_bucket == "tx01v2-lab-recovery-123456789012-us-west-2" &&
      one(aws_s3_bucket_replication_configuration.backup_recovery[0].rule).delete_marker_replication[0].status == "Disabled" &&
      one(aws_s3_bucket_replication_configuration.backup_recovery[0].rule).destination[0].encryption_configuration[0].replica_kms_key_id == module.kms_dr[0].key_arn &&
      aws_cloudwatch_metric_alarm.replica_lag[0].metric_name == "ReplicaLag" &&
      output.dr_contract_prefix == "/tx01v2/lab-dr"
    )
    error_message = "DR must have its own network/EKS/registry/KMS/database/contract, private DB access and inherited current credentials."
  }
  assert {
    condition = (
      length(aws_secretsmanager_secret.admin_token.replica) == 1 &&
      one(aws_secretsmanager_secret.admin_token.replica).region == "us-west-2" &&
      one(aws_secretsmanager_secret.admin_token.replica).kms_key_id == module.kms_dr[0].key_arn
    )
    error_message = "The existing admin credential must be natively replicated under the destination key."
  }
}

run "dr_rejects_overlapping_vpc" {
  command = plan
  variables {
    db_profile  = "dr"
    dr_vpc_cidr = "10.0.0.0/16"
  }
  expect_failures = [var.dr_vpc_cidr]
}

run "dr_rejects_public_vpc" {
  command = plan
  variables {
    db_profile  = "dr"
    dr_vpc_cidr = "192.0.2.0/16"
  }
  expect_failures = [var.dr_vpc_cidr]
}
