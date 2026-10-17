# Opt-in capacity lesson: preserve an on-demand default pool and taint disposable Spot capacity.
resource "aws_eks_node_group" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = aws_eks_cluster.this.version
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "SPOT"
  instance_types  = var.node_instance_types
  labels          = { "lab.capacity/pool" = "spot" }
  taint {
    key    = "lab.capacity/pool"
    value  = "spot"
    effect = "NO_SCHEDULE"
  }
  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = 2
  }
  update_config { max_unavailable = 1 }
  launch_template {
    id      = aws_launch_template.node.id
    version = tostring(aws_launch_template.node.latest_version)
  }
  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.before_compute]
}

resource "aws_autoscaling_group_tag" "spot_discovery" {
  for_each = var.enable_spot_pool ? merge(local.autoscaler_discovery_tags, {
    "k8s.io/cluster-autoscaler/node-template/label/lab.capacity/pool" = "spot"
    "k8s.io/cluster-autoscaler/node-template/taint/lab.capacity/pool" = "spot:NoSchedule"
  }) : {}

  autoscaling_group_name = aws_eks_node_group.spot[0].resources[0].autoscaling_groups[0].name
  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}
