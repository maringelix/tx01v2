# Permissions boundary of every IAM role the lab apply creates (docs/GUARDRAILS.md, SEC-11).
#
# The apply role may create and attach policies to tx01v2-* roles (it needs that for the EKS and Pod
# Identity roles), which would let it hand out any managed policy, AdministratorAccess included. The
# boundary caps what those roles can ever do: whatever is attached to them, they cannot change IAM,
# the organization or the account. The apply role can only create or re-bound a lab role with this
# boundary (roles.tf), and it cannot edit the boundary or take it off a role.
#
# The boundary caps lab roles to the service families in terraform/bootstrap/roles.tf. A new
# component needs an explicit service-family review before its identity can access another AWS API.

locals {
  lab_boundary_name = "${local.project}-lab-boundary"
  lab_boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.lab_boundary_name}"

  # IAM verbs that change anything. Reads (Get*, List*) stay: the load balancer controller reads
  # server certificates.
  boundary_denied_iam_actions = [
    "iam:Add*",
    "iam:Attach*",
    "iam:Change*",
    "iam:Create*",
    "iam:Deactivate*",
    "iam:Delete*",
    "iam:Detach*",
    "iam:Enable*",
    "iam:PassRole",
    "iam:Put*",
    "iam:Remove*",
    "iam:Reset*",
    "iam:Resync*",
    "iam:Set*",
    "iam:Tag*",
    "iam:Untag*",
    "iam:Update*",
    "iam:Upload*",
  ]
}

resource "aws_iam_policy" "lab_boundary" {
  name        = local.lab_boundary_name
  description = "Permissions boundary of the roles created by the ${local.project} apply role: no IAM, organization or account changes."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "LabServiceFamiliesOnly"
        Effect   = "Allow"
        Action   = local.lab_role_actions
        Resource = "*"
      },
      {
        # AmazonEKSWorkerNodePolicy allows this on the node role. The boundary must also
        # allow the EKS Auth API (a separate IAM service prefix from eks), or no Pod
        # Identity association can deliver credentials to the platform controllers.
        Sid    = "RetrievePodIdentityForLabClusters"
        Effect = "Allow"
        Action = "eks-auth:AssumeRoleForPodIdentity"
        Resource = [
          "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${local.lab_name}",
          "arn:${local.partition}:eks:${var.dr_region}:${local.account_id}:cluster/${local.lab_name}-dr",
        ]
      },
      {
        # An exception to Deny is not an Allow. In a new account the LBC must create
        # this one service-linked role before it can provision the first ALB.
        Sid      = "CreateOnlyTheElbServiceLinkedRole"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" }
        }
      },
      {
        Sid      = "VeleroBucketOnly"
        Effect   = "Allow"
        Action   = local.lab_velero_bucket_actions
        Resource = local.velero_bucket_arns
      },
      {
        Sid      = "VeleroObjectsOnly"
        Effect   = "Allow"
        Action   = local.lab_velero_object_actions
        Resource = local.velero_object_arns
      },
      {
        Sid      = "ReplicateTheLabBackupOnly"
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging", "s3:ReplicateObject", "s3:ReplicateTags"]
        Resource = concat(local.velero_bucket_arns, local.velero_object_arns)
      },
      ], local.lab_route53_boundary_statements, [
      {
        # The load balancer controller creates the service-linked role of Elastic Load Balancing the
        # first time it needs it: the one IAM write that stays.
        Sid      = "NoIamChangesExceptTheLoadBalancerServiceLinkedRole"
        Effect   = "Deny"
        Action   = local.boundary_denied_iam_actions
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Sid      = "NoOrganizationOrAccountChanges"
        Effect   = "Deny"
        Action   = ["organizations:*", "account:*"]
        Resource = "*"
      },
    ])
  })
}
