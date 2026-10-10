# EKS managed add-ons at the default version EKS selects for var.cluster_version.
# bootstrap_self_managed_addons = false means nothing exists until these are created:
# networking add-ons go before the nodes, Deployments (coredns, metrics-server) after them.

locals {
  addons_before_compute = {
    # Network policy enforcement for the NetworkPolicies shipped by dx01v2.
    "vpc-cni"                = jsonencode({ enableNetworkPolicy = "true" })
    "kube-proxy"             = null
    "eks-pod-identity-agent" = null
  }

  addons_after_compute = {
    "coredns"        = null
    "metrics-server" = null
  }
}

data "aws_eks_addon_version" "this" {
  for_each = merge(local.addons_before_compute, local.addons_after_compute)

  addon_name         = each.key
  kubernetes_version = var.cluster_version
  most_recent        = false
}

resource "aws_eks_addon" "before_compute" {
  for_each = local.addons_before_compute

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "after_compute" {
  for_each = local.addons_after_compute

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}
