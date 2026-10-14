# modules/waf and modules/kms tested directly.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  github_owner = "maringelix"
  name         = "tx01v2-lab"
  kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
}

run "waf_rules_and_logging" {
  command = apply

  module {
    source = "../../modules/waf"
  }

  assert {
    condition     = aws_wafv2_web_acl.this.scope == "REGIONAL" && one(aws_wafv2_web_acl.this.default_action[0].allow) != null
    error_message = "The web ACL must be REGIONAL (ALB) and allow by default."
  }

  assert {
    condition = { for r in aws_wafv2_web_acl.this.rule : r.name => r.priority } == {
      AWSManagedRulesAmazonIpReputationList = 0
      RateLimitPerClientIp                  = 1
      AWSManagedRulesCommonRuleSet          = 2
      AWSManagedRulesKnownBadInputsRuleSet  = 3
      AWSManagedRulesSQLiRuleSet            = 4
    }
    error_message = "Rules: IP reputation, rate limit, common rule set, known bad inputs and SQLi."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.this.rule : r.statement[0].rate_based_statement[0].limit if r.name == "RateLimitPerClientIp"]) == 1000
    error_message = "The rate-based rule must use var.rate_limit (default 1000 per 5 minutes)."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.name == "aws-waf-logs-tx01v2-lab" && aws_cloudwatch_log_group.waf.kms_key_id == var.kms_key_arn
    error_message = "WAF logs need a KMS-encrypted log group named aws-waf-logs-<name>."
  }

  assert {
    condition = (
      aws_wafv2_web_acl_logging_configuration.this.log_destination_configs == toset([aws_cloudwatch_log_group.waf.arn]) &&
      aws_wafv2_web_acl_logging_configuration.this.redacted_fields[0].single_header[0].name == "authorization"
    )
    error_message = "WAF logging must target the log group and redact the authorization header."
  }
}

run "kms_key" {
  command = apply

  module {
    source = "../../modules/kms"
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation && aws_kms_key.this.deletion_window_in_days == 7 && aws_kms_alias.this.name == "alias/tx01v2-lab"
    error_message = "The lab key must rotate, have a 7-day deletion window and the alias alias/tx01v2-lab."
  }

  assert {
    condition     = [for s in jsondecode(aws_kms_key.this.policy).Statement : s.Principal if s.Sid == "EnableIamPoliciesOfThisAccount"][0] == { AWS = "arn:aws:iam::123456789012:root" }
    error_message = "The key policy must delegate to IAM of this account."
  }

  assert {
    condition = [for s in jsondecode(aws_kms_key.this.policy).Statement : s if s.Sid == "AllowCloudWatchLogsOfThisAccountAndRegion"][0].Condition == {
      ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:us-east-1:123456789012:log-group:*" }
    }
    error_message = "CloudWatch Logs may use the key only for log groups of this account and region."
  }
}
