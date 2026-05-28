output "lambda_function_name" {
  description = "Name of the garbage collector Lambda function"
  value       = aws_lambda_function.garbage_collector.function_name
}

output "lambda_function_arn" {
  description = "ARN of the garbage collector Lambda function"
  value       = aws_lambda_function.garbage_collector.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge weekly schedule rule"
  value       = aws_cloudwatch_event_rule.weekly_cleanup.arn
}

output "eventbridge_schedule" {
  description = "Cron expression for the cleanup schedule"
  value       = aws_cloudwatch_event_rule.weekly_cleanup.schedule_expression
}

output "log_group_name" {
  description = "CloudWatch log group for Lambda execution logs"
  value       = aws_cloudwatch_log_group.garbage_collector.name
}
