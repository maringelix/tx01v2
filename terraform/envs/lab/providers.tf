provider "aws" {
  region = var.aws_region

  # Contract tags (docs/CONTRATO.md) on every resource that supports tags.
  default_tags {
    tags = local.default_tags
  }
}
