# AWS Budgets cost guardrail and its input validation.

mock_provider "aws" {
  source = "../tests/mocks"
}

variables {
  github_owner         = "maringelix"
  github_owner_id      = "1000000"
  tx01v2_repository_id = "2000000"
  dx01v2_repository_id = "3000000"
  budget_alert_emails  = ["lab-alerts@example.org", "ops@example.org"]
}

run "monthly_cost_budget_with_four_alerts" {
  command = plan

  assert {
    condition     = aws_budgets_budget.monthly.budget_type == "COST" && aws_budgets_budget.monthly.time_unit == "MONTHLY"
    error_message = "The budget must be a monthly COST budget."
  }

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "25.00" && aws_budgets_budget.monthly.limit_unit == "USD"
    error_message = "The default limit must be 25 USD."
  }

  assert {
    condition = toset([for n in aws_budgets_budget.monthly.notification : "${n.notification_type}:${n.threshold}"]) == toset([
      "ACTUAL:50",
      "ACTUAL:80",
      "ACTUAL:100",
      "FORECASTED:100",
    ])
    error_message = "Notifications must be ACTUAL 50/80/100 % and FORECASTED 100 %."
  }

  assert {
    condition = alltrue([
      for n in aws_budgets_budget.monthly.notification :
      n.threshold_type == "PERCENTAGE" && n.comparison_operator == "GREATER_THAN" &&
      n.subscriber_email_addresses == toset(["lab-alerts@example.org", "ops@example.org"])
    ])
    error_message = "Every notification must be a percentage threshold sent to all budget_alert_emails."
  }

  assert {
    condition     = aws_budgets_budget.monthly.cost_types[0].include_credit == false && aws_budgets_budget.monthly.cost_types[0].include_refund == false
    error_message = "Credits and refunds must not hide real usage."
  }
}

run "budget_limit_is_configurable" {
  command = plan

  variables {
    monthly_budget_usd = 10.5
  }

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "10.50"
    error_message = "monthly_budget_usd must reach the budget."
  }
}

run "rejects_an_invalid_email" {
  command = plan

  variables {
    budget_alert_emails = ["not-an-email"]
  }

  expect_failures = [var.budget_alert_emails]
}

run "rejects_an_empty_email_list" {
  command = plan

  variables {
    budget_alert_emails = []
  }

  expect_failures = [var.budget_alert_emails]
}

run "rejects_a_non_positive_budget" {
  command = plan

  variables {
    monthly_budget_usd = 0
  }

  expect_failures = [var.monthly_budget_usd]
}

run "placeholder_alert_email_is_refused" {
  command = plan

  variables {
    budget_alert_emails = ["YOU@example.com"]
  }

  expect_failures = [var.budget_alert_emails]
}
