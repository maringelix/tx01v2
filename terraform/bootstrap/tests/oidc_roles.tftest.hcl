mock_provider "aws" {
  alias  = "dr"
  source = "../tests/mocks"
}

# GitHub OIDC trust and the three contract roles (docs/CONTRATO.md).

mock_provider "aws" {
  source = "../tests/mocks"
}

variables {
  github_owner         = "maringelix"
  github_owner_id      = "1000000"
  tx01v2_repository_id = "2000000"
  dx01v2_repository_id = "3000000"
  budget_alert_emails  = ["lab-alerts@example.org"]
  lab_route53_zone_id  = "Z1234567890ABC"
}

run "trust_policies_allow_exactly_the_contract_subjects" {
  command = apply

  assert {
    condition = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:maringelix@1000000/tx01v2@2000000:pull_request",
      "repo:maringelix@1000000/tx01v2@2000000:ref:refs/heads/main",
    ]
    error_message = "tx01v2-gha-plan must trust exactly the tx01v2 pull_request and main subjects, in the immutable format with the owner and repository IDs."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] : !strcontains(s, ":environment:")
    ])
    error_message = "tx01v2-gha-plan must not trust any environment subject."
  }

  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:maringelix@1000000/tx01v2@2000000:environment:lab"]
    error_message = "tx01v2-gha-apply must trust only the environment lab of tx01v2, with the owner and repository IDs."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:maringelix@1000000/dx01v2@3000000:environment:lab"]
    error_message = "dx01v2-gha-deploy must trust only the environment lab of dx01v2, with the owner and repository IDs."
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
    github_owner         = "example-org"
    github_owner_id      = "42"
    tx01v2_repository_id = "4300"
    dx01v2_repository_id = "4400"
  }

  assert {
    condition     = jsondecode(aws_iam_role.apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:example-org@42/tx01v2@4300:environment:lab"]
    error_message = "The owner and the IDs in the sub claims must follow var.github_owner, github_owner_id and tx01v2_repository_id."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:example-org@42/dx01v2@4400:environment:lab"]
    error_message = "The deploy role must follow the owner and the dx01v2 repository ID too."
  }
}

run "existing_oidc_provider_is_read_not_created" {
  command = plan

  variables {
    create_github_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "No OIDC provider may be created when the account already has one."
  }

  assert {
    condition     = data.aws_iam_openid_connect_provider.existing[0].url == "https://token.actions.githubusercontent.com"
    error_message = "The existing provider is read by the GitHub URL."
  }

  assert {
    condition     = jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Trust policies must use the ARN of the existing provider."
  }
}

run "the_ids_are_numeric" {
  command = plan

  variables {
    tx01v2_repository_id = "tx01v2"
  }

  expect_failures = [var.tx01v2_repository_id]
}

run "role_permissions_follow_the_contract" {
  command = apply

  assert {
    condition = alltrue([
      for a in jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement[0].Action :
      can(regex("^[a-z0-9]+:(Describe|Get|List|BatchGet)[A-Za-z]*[*]?$", a))
    ])
    error_message = "The plan role may only read: every action must be a Describe, Get, List or BatchGet pattern."
  }

  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement[0].Action, "secretsmanager:GetSecretValue") && !contains(jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement[0].Action, "s3:GetObject") && !contains(jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement[0].Action, "s3:Get*")
    error_message = "The plan role must not read secret values or objects of other buckets (it is not ReadOnlyAccess of the account)."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement[1] == {
      Sid    = "DescribeTheVeleroBucket"
      Effect = "Allow"
      Action = ["s3:ListBucket", "s3:GetBucket*", "s3:GetAccelerateConfiguration", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration"]
      Resource = [
        "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1",
        "arn:aws:s3:::tx01v2-lab-dr-velero-123456789012-us-west-2",
        "arn:aws:s3:::tx01v2-lab-recovery-123456789012-us-west-2",
      ]
    }
    error_message = "The plan role reads the settings of the Velero bucket and no object of it or of any other bucket."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.plan_state.policy).Statement == [
      { Sid = "ListStateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1" },
      { Sid = "ReadLabState", Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1/lab/terraform.tfstate" },
    ]
    error_message = "The plan role may only read the lab state object."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Action if s.Sid == "ManageLabServiceFamilies"][0] == local.lab_service_actions &&
      !contains(local.lab_service_actions, "lambda:*") && !contains(local.lab_service_actions, "organizations:*")
    )
    error_message = "The apply role must allow only the lab's declared AWS service families, not all AWS services."
  }

  assert {
    condition = ([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Resource if s.Sid == "ManageTheVeleroBucket"][0] == [
      "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1",
      "arn:aws:s3:::tx01v2-lab-dr-velero-123456789012-us-west-2",
      "arn:aws:s3:::tx01v2-lab-recovery-123456789012-us-west-2",
      ] &&
      [for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Resource if s.Sid == "ManageObjectsInTheVeleroBucket"][0] == [
        "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1/*",
        "arn:aws:s3:::tx01v2-lab-dr-velero-123456789012-us-west-2/*",
        "arn:aws:s3:::tx01v2-lab-recovery-123456789012-us-west-2/*",
      ]
    )
    error_message = "The apply role may manage S3 only in the lab's Velero bucket and its objects."
  }

  assert {
    condition = ([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Resource if s.Sid == "ManageDnsValidationInTheConfiguredZone"][0] == "arn:aws:route53:::hostedzone/Z1234567890ABC" &&
      [for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Action if s.Sid == "ManageDnsValidationInTheConfiguredZone"][0] == ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
    )
    error_message = "DNS management by the apply role must be limited to the preconfigured hosted zone."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s if s.Sid == "NoAccountAdministration"][0].Effect == "Deny" &&
      [for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s if s.Sid == "NoAccountAdministration"][0].Action == ["account:*", "organizations:*", "billing:*", "ce:*", "support:*"]
    )
    error_message = "The apply role must deny account, organization, billing and support administration."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement : s.Resource if s.Sid == "ReadTheConfiguredDnsZone"][0] == "arn:aws:route53:::hostedzone/Z1234567890ABC" &&
      [for s in jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement : s.Action if s.Sid == "ReadTheConfiguredDnsZone"][0] == ["route53:GetHostedZone", "route53:ListResourceRecordSets"]
    )
    error_message = "The plan role may inspect only the hosted zone configured for the lab."
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
      s.Resource != "*" if s.Effect == "Allow" && s.Sid != "ReadIam" && s.Sid != "CreateRequiredServiceLinkedRoles"
    ])
    error_message = "Only IAM reads and the service-linked-role exception may use Resource = * in the IAM policy."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "CreateRequiredServiceLinkedRoles"][0].Condition == {
      StringEquals = {
        "iam:AWSServiceName" = [
          "eks.amazonaws.com",
          "eks-nodegroup.amazonaws.com",
          "elasticloadbalancing.amazonaws.com",
          "autoscaling.amazonaws.com",
          "rds.amazonaws.com",
        ]
      }
    }
    error_message = "Only the EKS, load balancer, Auto Scaling, and RDS service-linked roles used by the lab may be created."
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
          "arn:aws:ecr:us-west-2:123456789012:repository/dx01v2/api",
          "arn:aws:ecr:us-west-2:123456789012:repository/dx01v2/web",
        ]
      },
      { Sid = "DescribeLabCluster", Effect = "Allow", Action = "eks:DescribeCluster", Resource = [
        "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab",
        "arn:aws:eks:us-west-2:123456789012:cluster/tx01v2-lab-dr",
      ] },
      {
        Sid    = "ReadContractParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:aws:ssm:us-east-1:123456789012:parameter/tx01v2/lab/*",
          "arn:aws:ssm:us-west-2:123456789012:parameter/tx01v2/lab-dr/*",
        ]
      },
    ]
    error_message = "dx01v2-gha-deploy permissions must match the contract exactly."
  }
}

run "dns_permissions_are_absent_without_a_configured_zone" {
  command = apply

  variables {
    lab_route53_zone_id = ""
  }

  assert {
    condition = (
      length([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s if startswith(s.Sid, "ManageDns")]) == 0 &&
      length([for s in jsondecode(aws_iam_role_policy.plan_read_lab.policy).Statement : s if s.Sid == "ReadTheConfiguredDnsZone"]) == 0
    )
    error_message = "No GitHub role may inspect or change Route53 when the optional DNS zone is unset."
  }
}

run "invalid_dns_zone_id_is_rejected" {
  command = plan

  variables {
    lab_route53_zone_id = "not-a-zone"
  }

  expect_failures = [var.lab_route53_zone_id]
}

run "placeholder_owner_is_refused" {
  command = plan

  variables {
    github_owner = "your-github-user"
  }

  expect_failures = [var.github_owner]
}
