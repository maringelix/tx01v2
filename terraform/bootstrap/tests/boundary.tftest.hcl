# The permissions boundary of the lab roles and the conditions that make the apply role use it
# (docs/GUARDRAILS.md, SEC-11).

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

run "the_boundary_removes_iam_and_account_changes" {
  command = apply

  assert {
    condition     = aws_iam_policy.lab_boundary.name == "tx01v2-lab-boundary"
    error_message = "The boundary must be named tx01v2-lab-boundary: the lab root derives its ARN from the name."
  }

  assert {
    condition = alltrue([
      for a in ["iam:Add*", "iam:Attach*", "iam:Create*", "iam:Delete*", "iam:Detach*", "iam:PassRole", "iam:Put*", "iam:Set*", "iam:Update*"] :
      contains([for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "NoIamChangesExceptTheLoadBalancerServiceLinkedRole"][0].Action, a)
    ])
    error_message = "The boundary must deny every IAM verb that changes something, PassRole included."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s.Action if s.Sid == "LabServiceFamiliesOnly"][0] == local.lab_role_actions &&
      !contains(local.lab_role_actions, "lambda:*") && !contains(local.lab_role_actions, "iam:*")
    )
    error_message = "The permissions boundary must cap lab identities to the explicitly reviewed cloud service families."
  }

  assert {
    condition = ([for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "VeleroBucketOnly"][0] == {
      Sid      = "VeleroBucketOnly"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1"
    } && [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "VeleroObjectsOnly"][0].Resource == "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1/*")
    error_message = "The permissions boundary must restrict Velero S3 access to its bucket and objects."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "ConfiguredRoute53ZoneOnly"][0] == {
      Sid      = "ConfiguredRoute53ZoneOnly"
      Effect   = "Allow"
      Action   = ["route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
      Resource = "arn:aws:route53:::hostedzone/Z1234567890ABC"
    }
    error_message = "The permissions boundary must restrict workload DNS changes to the configured zone."
  }

  assert {
    condition = alltrue([
      for a in [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "NoIamChangesExceptTheLoadBalancerServiceLinkedRole"][0].Action :
      !startswith(a, "iam:Get") && !startswith(a, "iam:List")
    ])
    error_message = "The boundary keeps IAM reads: the load balancer controller reads server certificates."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "NoIamChangesExceptTheLoadBalancerServiceLinkedRole"][0].Condition == { StringNotEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" } }
    error_message = "Only the service-linked role of Elastic Load Balancing may be created by a lab role."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "NoOrganizationOrAccountChanges"][0].Action == ["organizations:*", "account:*"]
    error_message = "The boundary must deny the organization and the account APIs."
  }
}

run "the_boundary_has_no_dns_permissions_without_a_zone" {
  command = apply

  variables {
    lab_route53_zone_id = ""
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement :
      !startswith(s.Sid, "ConfiguredRoute53") && s.Sid != "DiscoverRoute53Zones"
    ])
    error_message = "A fork without a DNS zone must not grant Route53 permissions to workload identities."
  }
}

run "the_apply_role_creates_lab_roles_only_with_the_boundary" {
  command = apply

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "CreateLabRolesOnlyWithTheBoundary"][0] == {
      Sid       = "CreateLabRolesOnlyWithTheBoundary"
      Effect    = "Allow"
      Action    = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
      Resource  = "arn:aws:iam::123456789012:role/tx01v2-*"
      Condition = { StringEquals = { "iam:PermissionsBoundary" = "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary" } }
    }
    error_message = "iam:CreateRole and iam:PutRolePermissionsBoundary must require the lab boundary on tx01v2-* roles."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement :
      !contains(flatten([s.Action]), "iam:CreateRole") if s.Effect == "Allow" && s.Sid != "CreateLabRolesOnlyWithTheBoundary"
    ])
    error_message = "No other Allow statement of the apply role may create roles: without the boundary condition it would skip the boundary."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "KeepTheBoundaryOnLabRoles"][0] == { Sid = "KeepTheBoundaryOnLabRoles", Effect = "Deny", Action = "iam:DeleteRolePermissionsBoundary", Resource = "arn:aws:iam::123456789012:role/tx01v2-*" }
    error_message = "The apply role must not take the boundary off a lab role."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "KeepTheBoundaryPolicyAsIs"][0] == {
      Sid      = "KeepTheBoundaryPolicyAsIs"
      Effect   = "Deny"
      Action   = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"]
      Resource = "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary"
    }
    error_message = "The apply role must not edit the boundary policy (it matches the tx01v2-* policy pattern)."
  }

  assert {
    condition = alltrue([
      for a in ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary"] :
      contains([for s in jsondecode(aws_iam_role_policy.apply_lab.policy).Statement : s if s.Sid == "ProtectBootstrapRoles"][0].Action, a)
    ])
    error_message = "The apply role must not create or re-bound a tx01v2-gha-* role."
  }
}
