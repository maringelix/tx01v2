# Offline regressions for the AWS API calls made by the real cloud workflows.
# Provider mocking checks policy documents, not AWS authorization or provisioning.
mock_provider "aws" {
  source = "../tests/mocks"
}

mock_provider "aws" {
  alias  = "dr"
  source = "../tests/mocks"
}

variables {
  github_owner         = "maringelix"
  github_owner_id      = "1000000"
  tx01v2_repository_id = "2000000"
  dx01v2_repository_id = "3000000"
  budget_alert_emails  = ["lab-alerts@example.org"]
}

run "pod_identity_is_allowed_through_the_node_boundary" {
  command = apply

  assert {
    condition = [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "RetrievePodIdentityForLabClusters"] == [{
      Sid    = "RetrievePodIdentityForLabClusters"
      Effect = "Allow"
      Action = "eks-auth:AssumeRoleForPodIdentity"
      Resource = [
        "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab",
        "arn:aws:eks:us-west-2:123456789012:cluster/tx01v2-lab-dr",
      ]
    }]
    error_message = "The node's AmazonEKSWorkerNodePolicy needs a matching boundary Allow for the separate EKS Auth API, limited to the two lab clusters."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement :
      !contains(flatten([s.Action]), "eks-auth:*") && !contains(flatten([s.Action]), "*") &&
      (s.Effect != "Deny" || !anytrue([for a in flatten([s.Action]) : startswith(a, "eks-auth:")]))
    ])
    error_message = "The boundary must neither grant all EKS Auth actions nor explicitly deny the required Pod Identity call."
  }
}

run "only_the_elb_service_linked_role_is_allowed" {
  command = apply

  assert {
    condition = [for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s if s.Sid == "CreateOnlyTheElbServiceLinkedRole"] == [{
      Sid      = "CreateOnlyTheElbServiceLinkedRole"
      Effect   = "Allow"
      Action   = "iam:CreateServiceLinkedRole"
      Resource = "arn:aws:iam::123456789012:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
      Condition = {
        StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" }
      }
    }]
    error_message = "The LBC needs an actual boundary Allow to create the first ELB service-linked role, with exact ARN and service condition."
  }

  assert {
    condition = alltrue([
      for request in [
        { service = "elasticloadbalancing.amazonaws.com", arn = "arn:aws:iam::123456789012:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing", allowed = true },
        { service = "rds.amazonaws.com", arn = "arn:aws:iam::123456789012:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing", allowed = false },
        { service = "elasticloadbalancing.amazonaws.com", arn = "arn:aws:iam::123456789012:role/other-role", allowed = false },
        ] : (
        one([for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s.Resource if s.Sid == "CreateOnlyTheElbServiceLinkedRole"]) == request.arn &&
        one([for s in jsondecode(aws_iam_policy.lab_boundary.policy).Statement : s.Condition.StringEquals["iam:AWSServiceName"] if s.Sid == "CreateOnlyTheElbServiceLinkedRole"]) == request.service
      ) == request.allowed
    ])
    error_message = "The SLR exception must accept the owned ELB service role and reject another service or role ARN."
  }
}

run "apply_can_refresh_and_empty_only_the_lab_buckets" {
  command = apply

  assert {
    condition = alltrue([
      # Read path of aws_s3_bucket in the pinned AWS provider 6.68.0, followed by
      # the ListObjectVersions permission used by its force_destroy delete path.
      for action in [
        "s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketPolicy", "s3:GetBucketAcl",
        "s3:GetBucketCORS", "s3:GetBucketWebsite", "s3:GetBucketVersioning",
        "s3:GetAccelerateConfiguration", "s3:GetBucketRequestPayment", "s3:GetBucketLogging",
        "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration",
        "s3:GetEncryptionConfiguration", "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketTagging", "s3:ListBucketVersions",
      ] : contains(one([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Action if s.Sid == "ManageTheVeleroBucket"]), action)
    ])
    error_message = "The apply role must allow every pinned-provider bucket refresh call and version enumeration before destroying a non-empty versioned bucket."
  }

  assert {
    condition = (
      one([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Resource if s.Sid == "ManageTheVeleroBucket"]) == [
        "arn:aws:s3:::tx01v2-lab-velero-123456789012-us-east-1",
        "arn:aws:s3:::tx01v2-lab-dr-velero-123456789012-us-west-2",
        "arn:aws:s3:::tx01v2-lab-recovery-123456789012-us-west-2",
      ] &&
      contains(one([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement : s.Action if s.Sid == "ManageObjectsInTheVeleroBucket"]), "s3:DeleteObjectVersion") &&
      alltrue([for s in jsondecode(aws_iam_role_policy.apply_services.policy).Statement :
        alltrue([for action in flatten([s.Action]) : !strcontains(action, "*") if startswith(action, "s3:")])
      ])
    )
    error_message = "S3 refresh and deletion permissions must keep exact actions and the same three lab bucket ARNs; no s3:* or s3:Get* grant."
  }
}

run "promotion_can_resolve_digests_only_in_the_app_repositories" {
  command = apply

  assert {
    condition = (
      contains(one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action if s.Sid == "PushPullAppImages"]), "ecr:DescribeImages") &&
      one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "PushPullAppImages"]) == [
        "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/api",
        "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/web",
        "arn:aws:ecr:us-west-2:123456789012:repository/dx01v2/api",
        "arn:aws:ecr:us-west-2:123456789012:repository/dx01v2/web",
      ]
    )
    error_message = "deploy-aws.sh resolves every promoted digest with DescribeImages, scoped to the API/web repositories in the two lab Regions."
  }
}
