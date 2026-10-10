variable "name" {
  description = "Name prefix of the lab (tx01v2-lab). The key alias becomes alias/<name>."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before AWS deletes the key after terraform destroy (7-30). Validated by the caller."
  type        = number
  default     = 7
}
