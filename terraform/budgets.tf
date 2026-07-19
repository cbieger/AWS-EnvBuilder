# Account-wide monthly budgets warn operators before this development workspace
# becomes a billing surprise. They send notifications only; they never stop,
# resize, or delete infrastructure automatically. Normal Terraform destroy
# removes these workspace-owned budgets after it removes the runtime.
locals {
  monthly_cost_alerts_usd = {
    # AWS Free Tier is service-specific. A near-zero gross-cost budget is the
    # closest account-wide signal that usage has started producing charges.
    outside-free-usage = "0.01"
    one-dollar         = "1"
    five-dollars       = "5"
  }
}

resource "aws_budgets_budget" "monthly_cost_alert" {
  for_each = local.monthly_cost_alerts_usd

  account_id   = data.aws_caller_identity.current.account_id
  name         = "${local.name}-${each.key}-monthly"
  budget_type  = "COST"
  limit_amount = each.value
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits and refunds must not hide gross service charges. This makes the
  # near-zero budget useful even when promotional credits pay the final bill.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # Forecast alerts provide early warning when AWS has enough billing history
  # to calculate a forecast. New accounts may need about five weeks of history.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Actual-spend alerts remain important because billing data and forecasts are
  # delayed, and new accounts may not have a usable forecast yet.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
