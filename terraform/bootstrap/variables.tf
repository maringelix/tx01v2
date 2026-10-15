variable "aws_region" {
  description = "Region of the state bucket and of the lab (must match the lab aws_region)."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "The aws_region must look like us-east-1."
  }
}

variable "github_owner" {
  description = "GitHub owner of the tx01v2 and dx01v2 repositories (OIDC sub claims). No default: the roles trust only the repositories of this owner, so a fork must name its own."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.github_owner))
    error_message = "The github_owner must be a valid GitHub user or organization name."
  }

  validation {
    condition     = lower(var.github_owner) != "your-github-user"
    error_message = "Set github_owner to the GitHub user that owns your forks (terraform.tfvars.example holds a placeholder)."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of github_owner (gh api users/<owner> --jq .id; it works for organizations too). GitHub writes it, and the ID of the repository, into the OIDC sub claim of every repository created after 2026-07-15 (immutable subject claims). The trust policies pin both, so a deleted and re-registered account name does not inherit the lab."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]{0,15}$", var.github_owner_id))
    error_message = "The github_owner_id must be the numeric GitHub ID of the owner: gh api users/<owner> --jq .id"
  }
}

variable "tx01v2_repository_id" {
  description = "Numeric GitHub ID of your tx01v2 repository (gh api repos/<owner>/tx01v2 --jq .id)."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]{0,15}$", var.tx01v2_repository_id))
    error_message = "The tx01v2_repository_id must be the numeric ID of the repository: gh api repos/<owner>/tx01v2 --jq .id"
  }
}

variable "dx01v2_repository_id" {
  description = "Numeric GitHub ID of your dx01v2 repository (gh api repos/<owner>/dx01v2 --jq .id)."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]{0,15}$", var.dx01v2_repository_id))
    error_message = "The dx01v2_repository_id must be the numeric ID of the repository: gh api repos/<owner>/dx01v2 --jq .id"
  }
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider (one per account). Set false when the account already has it: it is then read by URL and never changed here. A provider created here belongs to the whole account, so take it out of the state before the teardown (docs/RUNBOOK.md, section 10)."
  type        = bool
  default     = true
}

variable "state_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the state bucket with all object versions (set true only for the final teardown)."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget of the account, in USD."
  type        = number
  default     = 25

  validation {
    condition     = var.monthly_budget_usd > 0 && var.monthly_budget_usd <= 1000
    error_message = "The monthly_budget_usd must be greater than 0 and at most 1000."
  }
}

variable "budget_alert_emails" {
  description = "E-mail addresses that receive the budget alerts (1-10)."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) >= 1 && length(var.budget_alert_emails) <= 10
    error_message = "Set between 1 and 10 addresses in budget_alert_emails."
  }

  validation {
    condition     = alltrue([for e in var.budget_alert_emails : can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}$", e))])
    error_message = "Every budget_alert_emails entry must be a valid e-mail address, e.g. you@example.com."
  }

  validation {
    condition     = !contains([for e in var.budget_alert_emails : lower(e)], "you@example.com")
    error_message = "Replace the placeholder you@example.com of terraform.tfvars.example with an address you read: the budget alerts are the only warning of a forgotten lab."
  }
}
