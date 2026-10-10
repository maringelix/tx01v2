output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "endpoint_public_access_cidrs" {
  description = "CIDRs allowed on the public API endpoint, as configured on the cluster."
  value       = aws_eks_cluster.this.vpc_config[0].public_access_cidrs
}

output "cluster_security_group_id" {
  description = "Security group EKS creates for the control plane and attaches to managed nodes (and therefore pods)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_log_group_name" {
  description = "CloudWatch log group of the control plane logs."
  value       = aws_cloudwatch_log_group.cluster.name
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.default.node_group_name
}

output "node_capacity_type" {
  description = "Capacity type of the managed node group (SPOT or ON_DEMAND)."
  value       = aws_eks_node_group.default.capacity_type
}

output "node_role_arn" {
  description = "IAM role of the nodes."
  value       = aws_iam_role.node.arn
}

output "load_balancer_controller_role_arn" {
  description = "Pod Identity role of kube-system/aws-load-balancer-controller."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "external_secrets_role_arn" {
  description = "Pod Identity role of external-secrets/external-secrets."
  value       = aws_iam_role.external_secrets.arn
}
