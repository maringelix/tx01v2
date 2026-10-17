mock_provider "aws" {
  source = "../../tests/mocks"
}

mock_provider "aws" {
  alias  = "dr"
  source = "../../tests/mocks"

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
