# Managed node group (AL2023, Spot by default) with a minimal launch template.
# v1 lessons: the launch template sets NO security groups (EKS then attaches the cluster security
# group, which nodes need to join), NO image_id/user_data (EKS supplies the AMI and bootstrap),
# and the node group sets NO disk_size (the root volume comes from the block device mapping).

resource "aws_iam_role" "node" {
  name                 = "${var.name}-node"
  description          = "EC2 role of the ${var.name} managed node group."
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "Ec2Nodes"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AmazonEKS_CNI_Policy stays on the node role on purpose: it is the EKS default, and keeping it off
# Pod Identity avoids making node networking (aws-node) depend on the Pod Identity agent during node
# bootstrap. The exposure is limited by the IMDS hop limit of 1 below: only hostNetwork pods
# (aws-node, kube-proxy, the Pod Identity agent) can reach the node credentials; application pods cannot.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonEKS_CNI_Policy",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "node" {
  name                   = "${var.name}-node"
  description            = "IMDSv2 only (hop limit 1) and an encrypted gp3 root volume for ${var.name} nodes."
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    # Root device of the EKS-optimized AL2023 AMIs.
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.node_disk_size_gb
      volume_type = "gp3"
      # The AWS managed EBS key: a customer managed key here would also need a key policy grant
      # for the Auto Scaling service-linked role, or instances fail to launch.
      encrypted             = "true"
      delete_on_termination = "true"
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.value
      tags          = merge(var.tags, { Name = "${var.name}-node" })
    }
  }

  tags = {
    Name = "${var.name}-node"
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = aws_eks_cluster.this.version
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = var.node_capacity_type
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = tostring(aws_launch_template.node.latest_version)
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_compute,
  ]
}
