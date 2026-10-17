variable "source_bucket_arn" { type = string }
variable "destination_name" { type = string }
variable "source_region" { type = string }
variable "destination_region" { type = string }
variable "account_id" { type = string }
variable "role_name" { type = string }
variable "source_kms_key_arn" {
  type    = string
  default = null
}
variable "destination_kms_key_arn" {
  type    = string
  default = null
}
variable "permissions_boundary_arn" {
  type    = string
  default = null
}
