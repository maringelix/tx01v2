# The three GitHub Actions roles of the contract (docs/CONTRATO.md).

locals {
  iam_arn_prefix   = "arn:${local.partition}:iam::${local.account_id}"
  state_bucket_arn = "arn:${local.partition}:s3:::${local.state_bucket_name}"
  lab_state_object_arns = [
    "${local.state_bucket_arn}/${local.lab_state_key}",
    "${local.state_bucket_arn}/${local.lab_state_key}.tflock",
  ]

  lab_route53_zone_arn    = var.lab_route53_zone_id == "" ? "" : "arn:${local.partition}:route53:::hostedzone/${var.lab_route53_zone_id}"
  lab_acm_certificate_arn = "arn:${local.partition}:acm:${local.region}:${local.account_id}:certificate/*"
  lab_acm_certificate_arns = distinct([
    local.lab_acm_certificate_arn,
    "arn:${local.partition}:acm:${var.dr_region}:${local.account_id}:certificate/*",
  ])

  # The apply identity can manage only service families used by this lab. Most create/delete APIs do
  # not support useful resource scoping before a resource exists; IAM, S3 and Route53 get narrower
  # statements below. The permissions boundary applies the same service-family cap to lab roles.
  lab_service_actions = [
    "acm:*",
    "autoscaling:*",
    "ec2:*",
    "ecr:*",
    "eks:*",
    "elasticloadbalancing:*",
    "kms:*",
    "logs:*",
    "rds:*",
    "secretsmanager:*",
    "shield:*",
    "ssm:*",
    "wafv2:*",
    "xray:*",
  ]
  # Route53 permissions are limited to the configured zone; Velero S3 is limited to its bucket.
  lab_velero_bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation"]
  lab_velero_object_actions = [
    "s3:GetObject",
    "s3:PutObject",
    "s3:PutObjectTagging",
    "s3:DeleteObject",
    "s3:AbortMultipartUpload",
    "s3:ListMultipartUploadParts",
  ]
  lab_role_actions = local.lab_service_actions

  apply_route53_statements = [
    for statement in [
      {
        Sid      = "ManageDnsValidationInTheConfiguredZone"
        Effect   = "Allow"
        Action   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
        Resource = local.lab_route53_zone_arn
      },
      {
        Sid      = "ReadDnsValidationChangeStatus"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "*"
      },
    ] : statement if var.lab_route53_zone_id != ""
  ]

  plan_route53_statements = [
    for statement in [
      {
        Sid      = "ReadTheConfiguredDnsZone"
        Effect   = "Allow"
        Action   = ["route53:GetHostedZone", "route53:ListResourceRecordSets"]
        Resource = local.lab_route53_zone_arn
      },
      {
        Sid      = "ReadDnsValidationChangeStatus"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "*"
      },
    ] : statement if var.lab_route53_zone_id != ""
  ]

  lab_route53_boundary_statements = [
    for statement in [
      {
        Sid      = "DiscoverRoute53Zones"
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Sid      = "ConfiguredRoute53ZoneOnly"
        Effect   = "Allow"
        Action   = ["route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
        Resource = local.lab_route53_zone_arn
      },
    ] : statement if var.lab_route53_zone_id != ""
  ]

  # IAM write actions the apply role may use on tx01v2-* roles, policies and instance profiles.
  # iam:CreateRole is not here: it is allowed only with the permissions boundary (boundary.tf).
  lab_iam_write_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy",
    "iam:TagRole",
    "iam:UntagRole",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy",
    "iam:CreatePolicy",
    "iam:DeletePolicy",
    "iam:CreatePolicyVersion",
    "iam:DeletePolicyVersion",
    "iam:SetDefaultPolicyVersion",
    "iam:TagPolicy",
    "iam:UntagPolicy",
    "iam:CreateInstanceProfile",
    "iam:DeleteInstanceProfile",
    "iam:AddRoleToInstanceProfile",
    "iam:RemoveRoleFromInstanceProfile",
    "iam:TagInstanceProfile",
    "iam:UntagInstanceProfile",
  ]

  # What `terraform plan` reads while it refreshes the lab: service-level Describe/Get/List of the
  # services of terraform/envs/lab, in place of ReadOnlyAccess (every service of the account, so
  # the data of any other workload). Reading a secret value, an object or a log event is not here.
  plan_read_actions = [
    "autoscaling:Describe*",
    "ec2:Describe*",
    "ec2:Get*",
    "ecr:BatchGet*",
    "ecr:Describe*",
    "ecr:Get*",
    "ecr:List*",
    "eks:Describe*",
    "eks:List*",
    "elasticloadbalancing:Describe*",
    "iam:Get*",
    "iam:List*",
    "kms:Describe*",
    "kms:Get*",
    "kms:List*",
    "logs:Describe*",
    "logs:List*",
    "rds:Describe*",
    "rds:List*",
    "secretsmanager:Describe*",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:List*",
    "ssm:Describe*",
    "ssm:Get*",
    "ssm:List*",
    "tag:Get*",
    "wafv2:Describe*",
    "wafv2:Get*",
    "wafv2:List*",
  ]

  ecr_repository_arns = [
    for pair in setproduct(distinct([local.region, var.dr_region]), ["dx01v2/api", "dx01v2/web"]) :
    "arn:${local.partition}:ecr:${pair[0]}:${local.account_id}:repository/${pair[1]}"
  ]

  # The backup bucket of Velero (terraform/modules/velero): the plan reads its settings, never an object.
  velero_bucket_arn = "arn:${local.partition}:s3:::${local.lab_name}-velero-${local.account_id}-${local.region}"
  velero_bucket_arns = [
    local.velero_bucket_arn,
    "arn:${local.partition}:s3:::${local.lab_name}-dr-velero-${local.account_id}-${var.dr_region}",
    "arn:${local.partition}:s3:::${local.lab_name}-recovery-${local.account_id}-${var.dr_region}",
  ]
  velero_object_arns = [for bucket in local.velero_bucket_arns : "${bucket}/*"]
  plan_read_velero_bucket_actions = [
    "s3:ListBucket",
    "s3:GetBucket*",
    "s3:GetAccelerateConfiguration",
    "s3:GetEncryptionConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration",
  ]
}

# --- tx01v2-gha-plan: PRs and main, read-only ---

resource "aws_iam_role" "plan" {
  name                 = "tx01v2-gha-plan"
  description          = "GitHub Actions (tx01v2 PRs and main): terraform plan of the lab, read-only on the services of the lab, -lock=false."
  assume_role_policy   = local.github_trust_policies["plan"]
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "plan_read_lab" {
  name = "read-lab-services"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "DescribeTheServicesOfTheLab"
        Effect   = "Allow"
        Action   = local.plan_read_actions
        Resource = "*"
      },
      {
        Sid      = "DescribeTheVeleroBucket"
        Effect   = "Allow"
        Action   = local.plan_read_velero_bucket_actions
        Resource = local.velero_bucket_arns
      },
      {
        Sid      = "DescribeLabAcmCertificates"
        Effect   = "Allow"
        Action   = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
        Resource = local.lab_acm_certificate_arns
      },
    ], local.plan_route53_statements)
  })
}

resource "aws_iam_role_policy" "plan_state" {
  name = "read-lab-state"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.state_bucket_arn
      },
      {
        Sid      = "ReadLabState"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.state_bucket_arn}/${local.lab_state_key}"
      },
    ]
  })
}

# --- tx01v2-gha-apply: environment lab only (required reviewer) ---

resource "aws_iam_role" "apply" {
  name                 = "tx01v2-gha-apply"
  description          = "GitHub Actions (tx01v2, environment lab): apply/platform/destroy of the lab."
  assume_role_policy   = local.github_trust_policies["apply"]
  max_session_duration = 7200
}

resource "aws_iam_role_policy" "apply_lab" {
  name = "lab-iam-and-state"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageLabIamOnly"
        Effect = "Allow"
        Action = local.lab_iam_write_actions
        Resource = [
          "${local.iam_arn_prefix}:role/tx01v2-*",
          "${local.iam_arn_prefix}:policy/tx01v2-*",
          "${local.iam_arn_prefix}:instance-profile/tx01v2-*",
        ]
      },
      {
        # A lab role is created, or given another boundary, only with the lab boundary.
        Sid      = "CreateLabRolesOnlyWithTheBoundary"
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource = "${local.iam_arn_prefix}:role/tx01v2-*"
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.lab_boundary_arn
          }
        }
      },
      {
        Sid      = "PassLabRolesOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "${local.iam_arn_prefix}:role/tx01v2-*"
      },
      {
        Sid      = "CreateRequiredServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
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
      },
      {
        Sid      = "ReadIam"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        # The CI identities created here are out of reach of the lab apply.
        Sid      = "ProtectBootstrapRoles"
        Effect   = "Deny"
        Action   = concat(local.lab_iam_write_actions, ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary", "iam:PassRole"])
        Resource = "${local.iam_arn_prefix}:role/tx01v2-gha-*"
      },
      {
        Sid      = "KeepTheBoundaryOnLabRoles"
        Effect   = "Deny"
        Action   = "iam:DeleteRolePermissionsBoundary"
        Resource = "${local.iam_arn_prefix}:role/tx01v2-*"
      },
      {
        Sid      = "KeepTheBoundaryPolicyAsIs"
        Effect   = "Deny"
        Action   = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"]
        Resource = local.lab_boundary_arn
      },
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.state_bucket_arn
      },
      {
        Sid      = "ReadWriteLabStateAndLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = local.lab_state_object_arns
      },
    ]
  })
}

resource "aws_iam_role_policy" "apply_services" {
  name = "lab-service-families-and-storage"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ManageLabServiceFamilies"
        Effect   = "Allow"
        Action   = local.lab_service_actions
        Resource = "*"
      },
      {
        Sid    = "ManageTheVeleroBucket"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:DeleteBucket",
          "s3:PutBucketOwnershipControls", "s3:GetBucketOwnershipControls",
          "s3:PutBucketPublicAccessBlock", "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPolicy", "s3:GetBucketPolicy", "s3:DeleteBucketPolicy",
          "s3:PutBucketTagging", "s3:GetBucketTagging",
          "s3:ListBucket", "s3:GetBucketLocation",
          "s3:PutEncryptionConfiguration", "s3:GetEncryptionConfiguration",
          "s3:PutLifecycleConfiguration", "s3:GetLifecycleConfiguration",
          "s3:PutBucketVersioning", "s3:GetBucketVersioning",
          "s3:PutReplicationConfiguration", "s3:GetReplicationConfiguration",
        ]
        Resource = local.velero_bucket_arns
      },
      {
        Sid      = "ManageObjectsInTheVeleroBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = local.velero_object_arns
      },
      {
        Sid      = "ManageOwnedReplicaLagAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = [for region in distinct([local.region, var.dr_region]) : "arn:${local.partition}:cloudwatch:${region}:${local.account_id}:alarm:tx01v2-lab-*"]
      },
      {
        Sid      = "NoAccountAdministration"
        Effect   = "Deny"
        Action   = ["account:*", "organizations:*", "billing:*", "ce:*", "support:*"]
        Resource = "*"
      },
    ], local.apply_route53_statements)
  })
}

# --- dx01v2-gha-deploy: dx01v2 environment lab only ---

resource "aws_iam_role" "deploy" {
  name                 = "dx01v2-gha-deploy"
  description          = "GitHub Actions (dx01v2, environment lab): push images and deploy the app."
  assume_role_policy   = local.github_trust_policies["deploy"]
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-dx01v2"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken does not support resource-level permissions.
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
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
        Resource = local.ecr_repository_arns
      },
      {
        Sid    = "DescribeLabCluster"
        Effect = "Allow"
        Action = "eks:DescribeCluster"
        Resource = [
          "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${local.lab_name}",
          "arn:${local.partition}:eks:${var.dr_region}:${local.account_id}:cluster/${local.lab_name}-dr",
        ]
      },
      {
        Sid    = "ReadContractParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${local.project}/${local.environment}/*",
          "arn:${local.partition}:ssm:${var.dr_region}:${local.account_id}:parameter/${local.project}/lab-dr/*",
        ]
      },
    ]
  })
}
