provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.default_tags
  }
}
provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags { tags = local.default_tags }
}
