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

output "scp_test_user_name" {
  description = "IAM username for SCP simulation testing"
  value       = aws_iam_user.scp_test_user.name
}

output "scp_test_user_access_key_id" {
  description = "Access key ID for the SCP test user — use with AWS CLI"
  value       = aws_iam_access_key.scp_test_user.id
}

output "scp_test_user_secret_access_key" {
  description = "Secret access key for the SCP test user"
  value       = aws_iam_access_key.scp_test_user.secret
  sensitive   = true
}
