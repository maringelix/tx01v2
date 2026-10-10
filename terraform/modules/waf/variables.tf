variable "name" {
  description = "Name prefix of the lab (tx01v2-lab)."
  type        = string
}

variable "rate_limit" {
  description = "Requests per client IP per 5 minutes before the rate-based rule blocks."
  type        = number
  default     = 1000
}

variable "log_retention_days" {
  description = "Retention of the WAF log group."
  type        = number
  default     = 7
}

variable "kms_key_arn" {
  description = "Lab KMS key used to encrypt the WAF log group."
  type        = string
}
