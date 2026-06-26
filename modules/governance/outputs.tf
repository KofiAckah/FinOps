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

# No access key is emitted by Terraform — that would persist the secret in
# state. Create a short-lived key for the deny tests with the command below,
# then delete it when finished:
#
#   aws iam delete-access-key --user-name finops-scp-test-user --access-key-id <id>
output "scp_test_user_key_command" {
  description = "Command to generate a temporary access key for the SCP test user"
  value       = "aws iam create-access-key --user-name ${aws_iam_user.scp_test_user.name}"
}
