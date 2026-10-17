# Negative tests: unsafe or invalid inputs must be rejected before anything is planned.

mock_provider "aws" {
  source = "../../tests/mocks"
}

mock_provider "aws" {
  alias  = "dr"
  source = "../../tests/mocks"
}

variables {
  github_owner                 = "maringelix"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
}

run "accepts_the_example_inputs" {
  command = plan
}

run "rejects_endpoint_open_to_the_world_without_opt_in" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "accepts_endpoint_open_to_the_world_with_explicit_opt_in" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
    allow_endpoint_from_anywhere = true
  }
}

run "rejects_an_empty_endpoint_cidr_list" {
  command = plan

  variables {
    endpoint_public_access_cidrs = []
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_a_non_canonical_endpoint_cidr" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["203.0.113.10/24"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_an_empty_cluster_admin_list" {
  command = plan

  variables {
    cluster_admin_principal_arns = []
  }

  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_an_assumed_role_session_arn_as_admin" {
  command = plan

  variables {
    cluster_admin_principal_arns = ["arn:aws:sts::123456789012:assumed-role/Admin/session"]
  }

  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_a_principal_in_both_access_lists" {
  command = plan

  variables {
    app_deployer_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  }

  expect_failures = [var.app_deployer_principal_arns]
}

run "rejects_a_bad_capacity_type" {
  command = plan

  variables {
    node_capacity_type = "spot"
  }

  expect_failures = [var.node_capacity_type]
}

run "rejects_a_bad_cluster_version" {
  command = plan

  variables {
    cluster_version = "1.36.1"
  }

  expect_failures = [var.cluster_version]
}

run "rejects_a_log_retention_cloudwatch_does_not_accept" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_inconsistent_node_sizes" {
  command = plan

  variables {
    node_desired_size = 4
    node_max_size     = 3
  }

  expect_failures = [var.node_desired_size]
}

run "rejects_more_than_three_azs" {
  command = plan

  variables {
    az_count = 4
  }

  expect_failures = [var.az_count]
}

run "rejects_a_non_canonical_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.0.1.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_a_short_secret_recovery_window" {
  command = plan

  variables {
    secret_recovery_window_days = 3
  }

  expect_failures = [var.secret_recovery_window_days]
}

run "placeholder_owner_is_refused" {
  command = plan

  variables {
    github_owner = "your-github-user"
  }

  expect_failures = [var.github_owner]
}
