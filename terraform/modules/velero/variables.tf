# Inputs are validated by the calling root (terraform/envs/lab); this module trusts them.

variable "name" {
  description = "Name prefix of the lab (tx01v2-lab). The bucket is <name>-velero-<account id>-<region>; platform/install.sh derives the same name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster where the Pod Identity association of Velero is created."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of that cluster: the trust policy of the role accepts only Pod Identity of this cluster."
  type        = string
}

variable "kms_key_arn" {
  description = "Lab KMS key that encrypts the backups."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary of the lab roles (the apply role can only create a role with it)."
  type        = string
}

variable "retention_days" {
  description = "Days after which the lifecycle rule expires a backup object. Keep it above the Velero backup TTL (720 h by default), or backups are cut short."
  type        = number
  default     = 35
}

variable "force_destroy" {
  description = "Delete the bucket with the backups inside (true for the lab so terraform destroy never blocks)."
  type        = bool
  default     = true
}
