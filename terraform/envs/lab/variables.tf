# Inputs of the lab root. Cloud workflows pass them as TF_VAR_* repository variables
# (lists as JSON strings); docs/RUNBOOK.md lists every one.

variable "aws_region" {
  description = "AWS region of the lab."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "The aws_region must look like us-east-1."
  }
}

variable "github_owner" {
  description = "GitHub owner of this repository; used in the Repository default tag."
  type        = string
  default     = "maringelix"

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.github_owner))
    error_message = "The github_owner must be a valid GitHub user or organization name."
  }
}

# --- Kubernetes API endpoint and access ---

variable "endpoint_public_access_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public EKS API endpoint, e.g. [\"203.0.113.10/32\"]. IAM authentication still applies."
  type        = list(string)

  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0
    error_message = "Set at least one CIDR in endpoint_public_access_cidrs, e.g. [\"<YOUR_IP>/32\"]."
  }

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(regex("^[0-9.]+/[0-9]{1,2}$", c)) && try(cidrsubnet(c, 0, 0) == c, false)])
    error_message = "Every endpoint_public_access_cidrs entry must be an IPv4 network in canonical form, e.g. 203.0.113.10/32 or 198.51.100.0/24."
  }

  validation {
    condition     = var.allow_endpoint_from_anywhere || !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "The CIDR 0.0.0.0/0 opens the API endpoint to the whole Internet: set allow_endpoint_from_anywhere = true to accept it explicitly (GitHub-hosted runners need it, see docs/ARQUITETURA.md)."
  }
}

variable "allow_endpoint_from_anywhere" {
  description = "Explicit opt-in required to use 0.0.0.0/0 in endpoint_public_access_cidrs."
  type        = bool
  default     = false
}

variable "cluster_admin_principal_arns" {
  description = "IAM role/user ARNs with AmazonEKSClusterAdminPolicy. Include tx01v2-gha-apply (platform and destroy workflows) and your admin role."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "Set at least one cluster admin: the cluster creator gets no implicit access (bootstrap_cluster_creator_admin_permissions = false)."
  }

  validation {
    condition     = alltrue([for a in var.cluster_admin_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]+$", a))])
    error_message = "Every cluster_admin_principal_arns entry must be an IAM role or user ARN starting with arn:aws:iam:: (not an sts assumed-role ARN)."
  }
}

variable "app_deployer_principal_arns" {
  description = "IAM role ARNs mapped to the Kubernetes group dx01v2-deployers (normally only dx01v2-gha-deploy)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.app_deployer_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]+$", a))])
    error_message = "Every app_deployer_principal_arns entry must be an IAM role or user ARN starting with arn:aws:iam::."
  }

  validation {
    condition     = length(setintersection(toset(var.app_deployer_principal_arns), toset(var.cluster_admin_principal_arns))) == 0
    error_message = "A principal can have only one EKS access entry: remove it from cluster_admin_principal_arns or app_deployer_principal_arns."
  }
}

# --- EKS ---

variable "cluster_version" {
  description = "Kubernetes minor version. 1.36 is in EKS standard support until 2027-08-02 (docs/SUSTENTACAO.md)."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.cluster_version))
    error_message = "The cluster_version must be a Kubernetes minor version such as 1.36."
  }
}

variable "node_capacity_type" {
  description = "SPOT (default, cheapest, can be interrupted) or ON_DEMAND."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "The node_capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "node_instance_types" {
  description = "Node instance types; more than one improves Spot availability."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0 && alltrue([for t in var.node_instance_types : can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", t))])
    error_message = "Set at least one valid instance type, e.g. t3.medium."
  }
}

variable "node_desired_size" {
  description = "Initial desired node count (later drift is ignored)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_min_size <= var.node_desired_size && var.node_desired_size <= var.node_max_size
    error_message = "The sizes must satisfy node_min_size <= node_desired_size <= node_max_size."
  }
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 0 && floor(var.node_min_size) == var.node_min_size
    error_message = "The node_min_size must be a non-negative integer."
  }
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size >= 1 && var.node_max_size <= 10 && floor(var.node_max_size) == var.node_max_size
    error_message = "The node_max_size must be an integer between 1 and 10."
  }
}

variable "node_disk_size_gb" {
  description = "Root gp3 volume of each node (set through the launch template)."
  type        = number
  default     = 20

  validation {
    condition     = var.node_disk_size_gb >= 20 && var.node_disk_size_gb <= 100
    error_message = "The node_disk_size_gb must be between 20 and 100."
  }
}

# --- Network ---

variable "vpc_cidr" {
  description = "VPC CIDR (/16 to /19)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(regex("^[0-9.]+/(1[6-9])$", var.vpc_cidr)) && try(cidrsubnet(var.vpc_cidr, 0, 0) == var.vpc_cidr, false)
    error_message = "The vpc_cidr must be a canonical IPv4 network with a prefix between /16 and /19, e.g. 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones (2-3)."
  type        = number
  default     = 2

  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "The az_count must be 2 or 3."
  }
}

variable "nat_gateway_per_az" {
  description = "false = a single NAT gateway (default, cheapest); true = one NAT gateway per AZ."
  type        = bool
  default     = false
}

# --- Logs, keys, secrets ---

variable "log_retention_days" {
  description = "Retention of every lab log group (flow logs, EKS control plane, RDS, WAF)."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "The log_retention_days must be a value accepted by CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before the lab KMS key is deleted after destroy."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "The kms_deletion_window_days must be between 7 and 30."
  }
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window: 0 deletes at once so the next round can reuse the names; otherwise 7-30."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "The secret_recovery_window_days must be 0 or between 7 and 30."
  }
}

variable "admin_token_version" {
  description = "Increment to generate a new admin token (write-only secret version)."
  type        = number
  default     = 1

  validation {
    condition     = var.admin_token_version >= 1 && floor(var.admin_token_version) == var.admin_token_version
    error_message = "The admin_token_version must be a positive integer."
  }
}

# --- RDS ---

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.db_instance_class))
    error_message = "The db_instance_class must look like db.t4g.micro."
  }
}

variable "db_allocated_storage_gb" {
  description = "Initial gp3 storage of the database."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage_gb >= 20 && var.db_allocated_storage_gb <= 100
    error_message = "The db_allocated_storage_gb must be between 20 and 100."
  }
}

variable "db_max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling of the database."
  type        = number
  default     = 50

  validation {
    condition     = var.db_max_allocated_storage_gb >= var.db_allocated_storage_gb && var.db_max_allocated_storage_gb <= 200
    error_message = "The db_max_allocated_storage_gb must be >= db_allocated_storage_gb and <= 200."
  }
}

variable "db_multi_az" {
  description = "Multi-AZ standby (doubles the RDS cost)."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (lab default: 1 day)."
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "The db_backup_retention_days must be between 1 and 35."
  }
}

variable "db_deletion_protection" {
  description = "RDS deletion protection (lab default: off, so destroy works in one step)."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (lab default: true, no leftover snapshot)."
  type        = bool
  default     = true
}

variable "db_password_version" {
  description = "Increment to rotate the database password (write-only arguments)."
  type        = number
  default     = 1

  validation {
    condition     = var.db_password_version >= 1 && floor(var.db_password_version) == var.db_password_version
    error_message = "The db_password_version must be a positive integer."
  }
}

# --- ECR and WAF ---

variable "ecr_force_delete" {
  description = "Delete ECR repositories that still hold images on destroy (lab default: true)."
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per client IP per 5 minutes before WAF blocks."
  type        = number
  default     = 1000

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000
    error_message = "The waf_rate_limit must be between 10 and 2000000000."
  }
}
