# Outputs provide the small set of identifiers an application developer or
# status helper actually needs; no credentials or sensitive values are exposed.
output "application_url" {
  description = "Public development URL. It is plain HTTP until an ACM certificate is deliberately added."
  value       = "http://${aws_lb.application.dns_name}"
}

output "ecr_repository_url" {
  description = "Registry path used by publish_app.sh."
  value       = aws_ecr_repository.application.repository_url
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group queried by the status helper."
  value       = aws_autoscaling_group.application.name
}

output "application_log_group" {
  description = "CloudWatch group containing container stdout and stderr."
  value       = aws_cloudwatch_log_group.application.name
}

output "bootstrap_error_log_group" {
  description = "Longer-retained CloudWatch group for instance setup failures."
  value       = aws_cloudwatch_log_group.errors.name
}

output "estimated_running_instance_range" {
  description = "Cost reminder: Auto Scaling may run any count in this range."
  value       = "${var.minimum_instances}-${var.maximum_instances} ${var.instance_type} instances"
}

output "monthly_cost_budget_names" {
  description = "Account-wide AWS Budgets that email on actual or forecast gross monthly spend beyond the configured thresholds."
  value       = sort([for budget in aws_budgets_budget.monthly_cost_alert : budget.name])
}
