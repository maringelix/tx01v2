# Bootstrap: applied once, locally, by a human with admin credentials (docs/RUNBOOK.md).
# Creates what the CI cannot create for itself: the state bucket, the GitHub OIDC trust,
# the three contract roles and the account cost budget.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  project     = "tx01v2"
  environment = "lab"
  lab_name    = "${local.project}-${local.environment}"

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  default_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Repository  = "${var.github_owner}/tx01v2"
    # Lets scripts/leftovers.sh tell bootstrap resources (kept between rounds) from lab ones.
    Stack = "bootstrap"
  }

  state_bucket_name = "${local.project}-tfstate-${local.account_id}-${local.region}"
  lab_state_key     = "lab/terraform.tfstate"
}
