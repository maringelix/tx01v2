# REGIONAL web ACL for the dx01v2 ALB. Terraform only creates it: the app Ingress attaches it
# through the alb.ingress.kubernetes.io/wafv2-acl-arn annotation (ARN published in SSM), so the
# ACL protects the load balancer that actually receives the traffic.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # AWS managed rule groups, evaluated in this order after the IP reputation list.
  managed_rule_groups = {
    AWSManagedRulesCommonRuleSet         = 2
    AWSManagedRulesKnownBadInputsRuleSet = 3
    AWSManagedRulesSQLiRuleSet           = 4
  }
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "Web ACL of the ${var.name} application load balancer."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerClientIp"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }
}

# WAF requires the aws-waf-logs- prefix for CloudWatch Logs destinations.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# Lets the log delivery service of this account write into the WAF log group.
resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name = "${var.name}-waf-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "WafLogDeliveryOfThisAccount"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.waf.arn}:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:*" }
      }
    }]
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Never log bearer tokens (dx01v2 admin calls use the Authorization header).
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
