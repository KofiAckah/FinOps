output "sns_topic_arn" {
  description = "ARN of the budget alert SNS topic"
  value       = aws_sns_topic.budget_alerts.arn
}

output "budget_name" {
  description = "Name of the AWS Budget"
  value       = aws_budgets_budget.monthly_cost.name
}

output "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  value       = "${aws_budgets_budget.monthly_cost.limit_amount} USD"
}

output "config_rule_name" {
  description = "Name of the AWS Config tagging rule"
  value       = aws_config_config_rule.require_costcenter_tag.name
}

output "config_s3_bucket" {
  description = "S3 bucket storing AWS Config findings"
  value       = aws_s3_bucket.config_logs.bucket
}
