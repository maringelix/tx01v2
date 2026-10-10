variable "repository_names" {
  description = "ECR repositories to create (contract: dx01v2/api, dx01v2/web)."
  type        = set(string)
}

variable "kms_key_arn" {
  description = "Lab KMS key used to encrypt the repositories."
  type        = string
}

variable "force_delete" {
  description = "Delete repositories even when they still contain images (true for the lab so destroy never blocks)."
  type        = bool
  default     = true
}

variable "keep_last_images" {
  description = "Number of images kept per repository by the lifecycle policy."
  type        = number
  default     = 20
}
