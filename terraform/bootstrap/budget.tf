# Account-wide monthly cost budget (use a dedicated AWS account for the lab).
# Credits and refunds are excluded so alerts follow real usage even while promotional credits
# hide the bill.

locals {
  budget_notifications = {
    "actual-50"      = { type = "ACTUAL", threshold = 50 }
    "actual-80"      = { type = "ACTUAL", threshold = 80 }
    "actual-100"     = { type = "ACTUAL", threshold = 100 }
    "forecasted-100" = { type = "FORECASTED", threshold = 100 }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.project}-monthly-cost"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = local.budget_notifications

    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
