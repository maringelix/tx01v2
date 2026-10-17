provider "aws" {
  region = var.aws_region

  # Contract tags (docs/CONTRATO.md) on every resource that supports tags.
  default_tags {
    tags = local.default_tags
  }
}

# Destination provider for the optional R9 DR profile. No resources use it in core/HA.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = local.default_tags
  }
}
