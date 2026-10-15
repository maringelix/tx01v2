# The three GitHub Actions roles of the contract (docs/CONTRATO.md).

locals {
  iam_arn_prefix   = "arn:${local.partition}:iam::${local.account_id}"
  state_bucket_arn = "arn:${local.partition}:s3:::${local.state_bucket_name}"
  lab_state_object_arns = [
    "${local.state_bucket_arn}/${local.lab_state_key}",
    "${local.state_bucket_arn}/${local.lab_state_key}.tflock",
  ]

  # IAM write actions the apply role may use on tx01v2-* roles, policies and instance profiles.
  lab_iam_write_actions = [
    "iam:CreateRole",
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

  ecr_repository_arns = [
    for repo in ["dx01v2/api", "dx01v2/web"] : "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${repo}"
  ]
}

# --- tx01v2-gha-plan: PRs and main, read-only ---

resource "aws_iam_role" "plan" {
  name                 = "tx01v2-gha-plan"
  description          = "GitHub Actions (tx01v2 PRs and main): terraform plan of the lab, read-only, -lock=false."
  assume_role_policy   = local.github_trust_policies["plan"]
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
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

resource "aws_iam_role_policy_attachment" "apply_power_user" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
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
        Sid      = "PassLabRolesOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "${local.iam_arn_prefix}:role/tx01v2-*"
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
        Action   = concat(local.lab_iam_write_actions, ["iam:PassRole"])
        Resource = "${local.iam_arn_prefix}:role/tx01v2-gha-*"
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
        Sid      = "DescribeLabCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${local.lab_name}"
      },
      {
        Sid      = "ReadContractParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${local.project}/${local.environment}/*"
      },
    ]
  })
}
