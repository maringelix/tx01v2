# GitHub OIDC trust and the three contract roles (docs/CONTRATO.md, contract v1).

mock_provider "aws" {
  source = "../tests/mocks"
}

variables {
  github_owner        = "maringelix"
  budget_alert_emails = ["lab-alerts@example.org"]
}

run "trust_policies_allow_exactly_the_contract_subjects" {
  command = apply

  assert {
    condition = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:maringelix/tx01v2:pull_request",
      "repo:maringelix/tx01v2:ref:refs/heads/main",
    ]
    error_message = "tx01v2-gha-plan must trust exactly the tx01v2 pull_request and main subjects."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] : !strcontains(s, ":environment:")
    ])
    error_message = "tx01v2-gha-plan must not trust any environment subject."
  }

  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:maringelix/tx01v2:environment:lab"]
    error_message = "tx01v2-gha-apply must trust only repo:maringelix/tx01v2:environment:lab."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:maringelix/dx01v2:environment:lab"]
    error_message = "dx01v2-gha-deploy must trust only repo:maringelix/dx01v2:environment:lab."
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.plan, aws_iam_role.apply, aws_iam_role.deploy] :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    ])
    error_message = "Every GitHub role must require the audience sts.amazonaws.com."
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.plan, aws_iam_role.apply, aws_iam_role.deploy] :
      keys(jsondecode(r.assume_role_policy).Statement[0].Condition) == ["StringEquals"] &&
      jsondecode(r.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(r.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github[0].arn &&
      length(jsondecode(r.assume_role_policy).Statement) == 1
    ])
    error_message = "Trust policies must be a single StringEquals statement (no StringLike wildcards) on the GitHub OIDC provider."
  }

  assert {
    condition     = [aws_iam_role.plan.name, aws_iam_role.apply.name, aws_iam_role.deploy.name] == ["tx01v2-gha-plan", "tx01v2-gha-apply", "dx01v2-gha-deploy"]
    error_message = "Role names must follow the contract."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The GitHub OIDC provider must be created by default with the sts.amazonaws.com client ID."
  }

  assert {
    condition = output.github_variables_tx01v2 == {
      AWS_REGION                       = "us-east-1"
      TF_STATE_BUCKET                  = "tx01v2-tfstate-123456789012-us-east-1"
      AWS_PLAN_ROLE_ARN                = aws_iam_role.plan.arn
      AWS_APPLY_ROLE_ARN               = aws_iam_role.apply.arn
      LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS = jsonencode([aws_iam_role.apply.arn])
      LAB_APP_DEPLOYER_PRINCIPAL_ARNS  = jsonencode([aws_iam_role.deploy.arn])
    }
    error_message = "github_variables_tx01v2 must hold the repository variables of docs/RUNBOOK.md known after the bootstrap."
  }

  assert {
    condition     = output.github_variables_dx01v2 == { AWS_REGION = "us-east-1", AWS_DEPLOY_ROLE_ARN = aws_iam_role.deploy.arn }
    error_message = "github_variables_dx01v2 must hold the region and the deploy role of the dx01v2 workflow."
  }
}

run "github_owner_is_configurable" {
  command = apply

  variables {
    github_owner = "example-org"
  }

  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:example-org/tx01v2:environment:lab"]
    error_message = "The owner in the sub claims must follow var.github_owner."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:example-org/dx01v2:environment:lab"]
    error_message = "The deploy role must follow var.github_owner too."
  }
}

run "existing_oidc_provider_is_reused" {
  command = plan

  variables {
    create_github_oidc_provider       = false
    existing_github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "No OIDC provider may be created when an existing one is reused."
  }

  assert {
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Trust policies must use the existing provider ARN."
  }
}

run "reuse_requires_the_existing_provider_arn" {
  command = plan

  variables {
    create_github_oidc_provider = false
  }

  expect_failures = [var.existing_github_oidc_provider_arn]
}

run "role_permissions_follow_the_contract" {
  command = apply

  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan role must be read-only (ReadOnlyAccess)."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.plan_state.policy).Statement == [
      { Sid = "ListStateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1" },
      { Sid = "ReadLabState", Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1/lab/terraform.tfstate" },
    ]
    error_message = "The plan role may only read the lab state object."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.apply_power_user.policy_arn == "arn:aws:iam::aws:policy/PowerUserAccess"
    error_message = "The apply role must use PowerUserAccess."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s.Resource if s.Sid == "ManageLabIamOnly"][0] == [
      "arn:aws:iam::123456789012:role/tx01v2-*",
      "arn:aws:iam::123456789012:policy/tx01v2-*",
      "arn:aws:iam::123456789012:instance-profile/tx01v2-*",
    ]
    error_message = "IAM write permissions of the apply role must be scoped to tx01v2-* names."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement :
      s.Resource != "*" if s.Effect == "Allow" && s.Sid != "ReadIam"
    ])
    error_message = "Only the IAM read statement of the apply role may use Resource = *."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s.Action if s.Sid == "ReadIam"][0] == ["iam:Get*", "iam:List*"]
    error_message = "The wildcard statement of the apply role must stay read-only."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "ProtectBootstrapRoles"][0].Effect == "Deny" && [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "ProtectBootstrapRoles"][0].Resource == "arn:aws:iam::123456789012:role/tx01v2-gha-*"
    error_message = "The apply role must not be able to modify the GitHub roles."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s.Resource if s.Sid == "ReadWriteLabStateAndLock"][0] == [
      "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1/lab/terraform.tfstate",
      "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1/lab/terraform.tfstate.tflock",
    ]
    error_message = "The apply role writes only the lab state object and its S3 lock file."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.deploy.policy).Statement == [
      { Sid = "EcrLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid    = "PushPullAppImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/api",
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/web",
        ]
      },
      { Sid = "DescribeLabCluster", Effect = "Allow", Action = "eks:DescribeCluster", Resource = "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab" },
      {
        Sid      = "ReadContractParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:us-east-1:123456789012:parameter/tx01v2/lab/*"
      },
    ]
    error_message = "dx01v2-gha-deploy permissions must match contract v1 exactly."
  }
}

run "placeholder_owner_is_refused" {
  command = plan

  variables {
    github_owner = "your-github-user"
  }

  expect_failures = [var.github_owner]
}
