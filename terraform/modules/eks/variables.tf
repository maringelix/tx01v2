# Inputs are validated by the calling root (terraform/envs/lab); this module trusts them.

variable "secrets_name_prefix" {
  description = "Optional credential name prefix, for native Secrets Manager replicas that retain the primary name."
  type        = string
  default     = null
}

variable "name" {
  description = "Cluster name and name prefix (tx01v2-lab)."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version of the control plane and nodes, e.g. \"1.36\"."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and the managed node group."
  type        = list(string)
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (IAM authentication still applies)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Lab KMS key: Kubernetes secrets envelope encryption and the control plane log group."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of /aws/eks/<name>/cluster."
  type        = number
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND."
  type        = string
}

variable "node_instance_types" {
  description = "Instance types of the managed node group (several types improve Spot availability)."
  type        = list(string)
}

variable "node_desired_size" {
  description = "Initial desired node count (later drift is ignored, e.g. manual scaling)."
  type        = number
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
}

variable "node_disk_size_gb" {
  description = "Root gp3 volume size, set through the launch template (never disk_size on the node group)."
  type        = number
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals that get AmazonEKSClusterAdminPolicy (cluster scope) through access entries."
  type        = list(string)
}

variable "app_deployer_principal_arns" {
  description = "IAM principals that get a STANDARD access entry in the Kubernetes group dx01v2-deployers."
  type        = list(string)
}

variable "tags" {
  description = "Tags copied to node EC2 instances, volumes and ENIs through the launch template (provider default_tags do not reach them)."
  type        = map(string)
  default     = {}
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary of every IAM role of the module (the bootstrap policy tx01v2-lab-boundary; the apply role can create a role only with it)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "The permissions_boundary_arn must be the ARN of an IAM policy."
  }
}
