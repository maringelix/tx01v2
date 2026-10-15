# Permissions boundary of every IAM role the lab apply creates (docs/GUARDRAILS.md, SEC-11).
#
# The apply role may create and attach policies to tx01v2-* roles (it needs that for the EKS and Pod
# Identity roles), which would let it hand out any managed policy, AdministratorAccess included. The
# boundary caps what those roles can ever do: whatever is attached to them, they cannot change IAM,
# the organization or the account. The apply role can only create or re-bound a lab role with this
# boundary (roles.tf), and it cannot edit the boundary or take it off a role.
#
# The boundary only removes: it does not list the services of the lab, so a new component of the
# platform does not need a change here. The data-plane limits of each role are its own policies.

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
    Statement = [
      {
        Sid      = "TheBoundaryOnlyRemoves"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
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
    ]
  })
}
