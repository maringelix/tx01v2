variable "name" {
  description = "Name prefix of the lab (tx01v2-lab)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (prefix /16 to /19). Public subnets take newbits 8, private subnets newbits 4."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (2-3). Validated by the caller."
  type        = number
  default     = 2
}

variable "nat_gateway_per_az" {
  description = "false = one NAT gateway shared by every AZ (cheapest); true = one NAT gateway per AZ."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention of the VPC flow logs log group (a CloudWatch Logs allowed value)."
  type        = number
  default     = 7
}

variable "kms_key_arn" {
  description = "ARN of the lab KMS key used to encrypt the flow logs log group."
  type        = string
}
