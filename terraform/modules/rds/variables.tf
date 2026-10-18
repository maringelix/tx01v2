# Inputs are validated by the calling root (terraform/envs/lab); this module trusts them.

variable "secret_replica_keys" {
  description = "Optional destination region => KMS ARN for native Secrets Manager credential replication."
  type        = map(string)
  default     = {}
}

variable "name" {
  description = "Name prefix of the lab (tx01v2-lab). The secret becomes <name>/db/app."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the database security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets of the DB subnet group."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach PostgreSQL on 5432, keyed by a static label (e.g. { eks_cluster = <sg-id> })."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "Lab KMS key: storage encryption, the secret and the log groups."
  type        = string
}

variable "instance_class" {
  description = "DB instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial gp3 storage."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "dx01v2"
}

variable "username" {
  description = "Master user name (the lab app uses it; see docs/ARCHITECTURE.md)."
  type        = string
  default     = "dx01v2_admin"
}

variable "multi_az" {
  description = "Multi-AZ standby (doubles the instance cost)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Deletion protection (off so the lab can be destroyed in one step)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (avoids leftover snapshot storage)."
  type        = bool
  default     = true
}

variable "delete_automated_backups" {
  description = "Delete automated backups with the instance; disable for a recovery window after teardown."
  type        = bool
  default     = true
}

variable "password_version" {
  description = "Increment to rotate the password: it drives password_wo_version and secret_string_wo_version together."
  type        = number
  default     = 1
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window; 0 deletes immediately so the next lab round can reuse the name."
  type        = number
  default     = 0
}

variable "log_retention_days" {
  description = "Retention of the RDS log groups."
  type        = number
  default     = 7
}
