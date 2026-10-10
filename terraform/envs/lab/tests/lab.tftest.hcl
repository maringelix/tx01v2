# Root-level wiring of the lab: contract SSM parameters, write-only admin token, lab-friendly
# defaults and the values that flow from the root variables into the modules.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  endpoint_public_access_cidrs = ["203.0.113.10/32", "198.51.100.0/24"]
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
}

run "defaults_are_lab_friendly" {
  command = plan

  assert {
    condition     = var.node_capacity_type == "SPOT" && var.node_instance_types == tolist(["t3.medium", "t3a.medium"])
    error_message = "Nodes must default to SPOT t3.medium/t3a.medium."
  }

  assert {
    condition     = var.node_desired_size == 2 && var.node_min_size == 1 && var.node_max_size == 3
    error_message = "Node group sizes must default to desired 2 / min 1 / max 3."
  }

  assert {
    condition     = var.cluster_version == "1.36" && var.nat_gateway_per_az == false && var.az_count == 2
    error_message = "Defaults must be Kubernetes 1.36, a single NAT gateway and two AZs."
  }

  assert {
    condition     = var.db_multi_az == false && var.db_backup_retention_days == 1 && var.db_deletion_protection == false && var.db_skip_final_snapshot
    error_message = "RDS defaults must be single-AZ, 1-day backups, destroyable without a final snapshot."
  }

  assert {
    condition     = var.allow_endpoint_from_anywhere == false && var.secret_recovery_window_days == 0 && var.ecr_force_delete
    error_message = "The endpoint must not be open by default; secrets and ECR must not block the next round."
  }

  assert {
    condition     = local.default_tags == { Project = "tx01v2", Environment = "lab", ManagedBy = "terraform", Repository = "maringelix/tx01v2" }
    error_message = "Provider default_tags must match the contract."
  }
}

run "contract_ssm_parameters_and_wiring" {
  command = apply

  assert {
    condition = sort([for p in aws_ssm_parameter.contract : p.name]) == sort([
      "/tx01v2/lab/region",
      "/tx01v2/lab/cluster-name",
      "/tx01v2/lab/vpc-id",
      "/tx01v2/lab/vpc-cidr",
      "/tx01v2/lab/ecr/api-url",
      "/tx01v2/lab/ecr/web-url",
      "/tx01v2/lab/waf/acl-arn",
      "/tx01v2/lab/db/secret-name",
      "/tx01v2/lab/app/admin-token-secret-name",
      "/tx01v2/lab/eso/cluster-secret-store",
    ])
    error_message = "The lab must publish exactly the ten contract SSM parameters."
  }

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.contract : p.type == "String"])
    error_message = "Contract parameters are of type String."
  }

  assert {
    condition = {
      for k in ["region", "cluster-name", "vpc-cidr", "db/secret-name", "app/admin-token-secret-name", "eso/cluster-secret-store"] :
      k => aws_ssm_parameter.contract[k].insecure_value
      } == {
      "region"                      = "us-east-1"
      "cluster-name"                = "tx01v2-lab"
      "vpc-cidr"                    = "10.0.0.0/16"
      "db/secret-name"              = "tx01v2-lab/db/app"
      "app/admin-token-secret-name" = "tx01v2-lab/app/admin-token"
      "eso/cluster-secret-store"    = "aws-secrets-manager"
    }
    error_message = "Static contract values are wrong."
  }

  assert {
    condition     = aws_ssm_parameter.contract["waf/acl-arn"].insecure_value == module.waf.web_acl_arn && aws_ssm_parameter.contract["vpc-id"].insecure_value == module.network.vpc_id
    error_message = "waf/acl-arn and vpc-id must come from the modules."
  }

  assert {
    condition     = aws_ssm_parameter.contract["ecr/api-url"].insecure_value == module.ecr.repository_urls["dx01v2/api"] && aws_ssm_parameter.contract["ecr/web-url"].insecure_value == module.ecr.repository_urls["dx01v2/web"]
    error_message = "ECR URLs must come from the ECR module."
  }

  assert {
    condition     = module.eks.endpoint_public_access_cidrs == toset(["203.0.113.10/32", "198.51.100.0/24"])
    error_message = "endpoint_public_access_cidrs must reach the EKS cluster unchanged."
  }

  assert {
    condition     = module.eks.node_capacity_type == "SPOT" && module.eks.cluster_version == "1.36"
    error_message = "The node group must run on SPOT by default and the cluster on 1.36."
  }

  assert {
    condition     = length(module.network.nat_gateway_ids) == 1
    error_message = "The lab must use a single NAT gateway by default."
  }

  assert {
    condition     = output.update_kubeconfig_command == "aws eks update-kubeconfig --region us-east-1 --name tx01v2-lab"
    error_message = "update_kubeconfig_command is wrong."
  }

  assert {
    condition     = length(output.ssm_parameter_names) == 10
    error_message = "ssm_parameter_names must list the ten parameters."
  }
}

run "admin_token_is_write_only" {
  command = apply

  assert {
    condition     = aws_secretsmanager_secret.admin_token.name == "tx01v2-lab/app/admin-token" && aws_secretsmanager_secret.admin_token.kms_key_id == module.kms.key_arn
    error_message = "The admin token secret must follow the contract name and use the lab key."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.admin_token.secret_string == null && aws_secretsmanager_secret_version.admin_token.secret_string_wo == null
    error_message = "The admin token must never be stored in state."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.admin_token.secret_string_wo_version == 1
    error_message = "The admin token is set through secret_string_wo (version 1 by default)."
  }

  assert {
    condition     = aws_secretsmanager_secret.admin_token.recovery_window_in_days == 0
    error_message = "Secrets must be deleted at once by default so the next round can reuse the name."
  }
}

run "a_per_az_nat_and_a_rotated_token_are_opt_in" {
  command = plan

  variables {
    nat_gateway_per_az  = true
    admin_token_version = 2
  }

  assert {
    condition     = aws_secretsmanager_secret_version.admin_token.secret_string_wo_version == 2
    error_message = "admin_token_version must drive the write-only version."
  }

  assert {
    condition     = length(module.network.nat_gateway_ids) == 2
    error_message = "nat_gateway_per_az = true must create one NAT gateway per AZ."
  }
}
