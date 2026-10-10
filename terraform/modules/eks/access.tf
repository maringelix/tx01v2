# Cluster access through EKS access entries (authentication_mode = "API"): no aws-auth
# ConfigMap and no system:masters. The cluster creator gets no implicit admin access.

resource "aws_eks_access_entry" "cluster_admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  for_each = aws_eks_access_entry.cluster_admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# The dx01v2 deploy role: no access policy; Kubernetes RBAC (platform/manifests) binds the
# group dx01v2-deployers to the Role dx01v2-deployer in the dx01v2 namespace only.
resource "aws_eks_access_entry" "app_deployer" {
  for_each = toset(var.app_deployer_principal_arns)

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value
  type              = "STANDARD"
  kubernetes_groups = ["dx01v2-deployers"]
}
