# The controller is installed by platform/install.sh and uses this exact Pod Identity.
resource "aws_iam_role" "cluster_autoscaler" {
  name                 = "${var.name}-cluster-autoscaler"
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "owned-node-groups"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadCapacity"
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeLaunchConfigurations", "autoscaling:DescribeScalingActivities", "autoscaling:DescribeTags", "ec2:DescribeImages", "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplateVersions", "ec2:GetInstanceTypesFromInstanceRequirements"]
        Resource = "*"
      },
      {
        Sid      = "ReadOwnedNodeGroups"
        Effect   = "Allow"
        Action   = ["eks:DescribeNodegroup"]
        Resource = "arn:${local.partition}:eks:${local.region}:${local.account_id}:nodegroup/${var.name}/*/*"
      },
      {
        Sid      = "ScaleTaggedOwnedGroups"
        Effect   = "Allow"
        Action   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        Resource = "arn:${local.partition}:autoscaling:${local.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"     = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.name}" = "owned"
          }
        }
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn
}

locals {
  autoscaler_discovery_tags = {
    "k8s.io/cluster-autoscaler/enabled"     = "true"
    "k8s.io/cluster-autoscaler/${var.name}" = "owned"
  }
}

resource "aws_autoscaling_group_tag" "default_discovery" {
  for_each = local.autoscaler_discovery_tags

  autoscaling_group_name = aws_eks_node_group.default.resources[0].autoscaling_groups[0].name
  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}
