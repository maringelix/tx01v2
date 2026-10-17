# Shared mock data for `terraform test` (mock_provider "aws" { source = ".../tests/mocks" }).
# No AWS account is ever contacted. Values use the AWS documentation account 123456789012.
# ARNs must be well formed because the real provider schema still validates arguments
# (for example role_arn or kms_key_id) once mocked values become known during apply.

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATERRAFORMTEST00000"
  }
}

mock_data "aws_region" {
  defaults = {
    region      = "us-east-1"
    description = "US East (N. Virginia)"
    endpoint    = "ec2.us-east-1.amazonaws.com"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

mock_data "aws_availability_zones" {
  defaults = {
    names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
    zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
  }
}

mock_data "aws_route53_zone" {
  defaults = {
    name         = "example.org."
    zone_id      = "Z1234567890ABC"
    private_zone = false
  }
}

mock_data "aws_eks_addon_version" {
  defaults = {
    version = "v0.0.0-eksbuild.1"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/mock-role"
  }
}

mock_resource "aws_iam_policy" {
  defaults = {
    arn = "arn:aws:iam::123456789012:policy/mock-policy"
  }
}

mock_data "aws_iam_openid_connect_provider" {
  defaults = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

mock_resource "aws_iam_openid_connect_provider" {
  defaults = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

mock_resource "aws_s3_bucket" {
  defaults = {
    arn = "arn:aws:s3:::tx01v2-tfstate-123456789012-us-east-1"
  }
}

mock_resource "aws_kms_key" {
  defaults = {
    arn    = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    key_id = "1234abcd-12ab-34cd-56ef-1234567890ab"
  }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = {
    arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
  }
}

mock_resource "aws_eks_cluster" {
  defaults = {
    arn      = "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab"
    endpoint = "https://0123456789ABCDEF.gr7.us-east-1.eks.amazonaws.com"
  }
}

mock_resource "aws_launch_template" {
  defaults = {
    id             = "lt-0123456789abcdef0"
    latest_version = 1
  }
}

mock_resource "aws_eks_node_group" {
  defaults = {
    # Sentinel for a computed attribute: it survives only when the configuration does NOT
    # set disk_size, which is what tests/eks.tftest.hcl asserts.
    disk_size = -1
    resources = [{
      autoscaling_groups              = [{ name = "eks-default-example" }]
      remote_access_security_group_id = ""
    }]
  }
}

mock_resource "aws_wafv2_web_acl" {
  defaults = {
    arn = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/tx01v2-lab/1234abcd-12ab-34cd-56ef-1234567890ab"
  }
}

mock_resource "aws_acm_certificate" {
  defaults = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/1234abcd-12ab-34cd-56ef-1234567890ab"
    domain_validation_options = [
      {
        domain_name           = "app.example.org"
        resource_record_name  = "_1234abcd.app.example.org."
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.acm-validations.aws."
      }
    ]
  }
}

mock_resource "aws_acm_certificate_validation" {
  defaults = {
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/1234abcd-12ab-34cd-56ef-1234567890ab"
  }
}

mock_resource "aws_route53_record" {
  defaults = {
    fqdn = "_1234abcd.app.example.org."
  }
}

mock_resource "aws_ecr_repository" {
  defaults = {
    arn            = "arn:aws:ecr:us-east-1:123456789012:repository/mock"
    repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mock"
  }
}

mock_resource "aws_secretsmanager_secret" {
  defaults = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:mock-AbCdEf"
  }
}

mock_resource "aws_db_instance" {
  defaults = {
    arn         = "arn:aws:rds:us-east-1:123456789012:db:tx01v2-lab-postgres"
    address     = "tx01v2-lab-postgres.abcdefghijkl.us-east-1.rds.amazonaws.com"
    resource_id = "db-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  }
}
