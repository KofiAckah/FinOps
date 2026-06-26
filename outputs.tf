# ─── Part 1 — zombie resources ─────────────────────────────────────────────────

output "zombie_idle_ec2_instance_id" {
  description = "ID of the idle EC2 instance"
  value       = module.zombie.idle_ec2_instance_id
}

output "zombie_unattached_ebs_volume_id" {
  description = "ID of the unattached EBS volume"
  value       = module.zombie.unattached_ebs_volume_id
}

output "zombie_unassociated_eip" {
  description = "Public IP of the unassociated Elastic IP"
  value       = module.zombie.unassociated_eip_public_ip
}

# ─── Part 1 — garbage collector ────────────────────────────────────────────────

output "garbage_collector_function_name" {
  description = "Name of the garbage collector Lambda (invoke this to run cleanup on demand)"
  value       = module.cleanup.lambda_function_name
}

output "garbage_collector_schedule" {
  description = "Cron schedule for automated cleanup"
  value       = module.cleanup.eventbridge_schedule
}

# ─── Part 2 — governance ───────────────────────────────────────────────────────

output "budget_name" {
  description = "Name of the AWS Budget"
  value       = module.governance.budget_name
}

output "sns_topic_arn" {
  description = "Budget alert SNS topic ARN"
  value       = module.governance.sns_topic_arn
}

output "config_rule_name" {
  description = "AWS Config tagging rule"
  value       = module.governance.config_rule_name
}

output "scp_test_user_key_command" {
  description = "Command to mint a temporary access key for SCP deny-policy testing"
  value       = module.governance.scp_test_user_key_command
}

# ─── Part 3 — optimization ─────────────────────────────────────────────────────

output "asg_name" {
  description = "Name of the mixed-instances Auto Scaling Group"
  value       = module.optimize.asg_name
}

output "asg_spot_instance_types" {
  description = "Instance types available for Spot capacity"
  value       = module.optimize.spot_instance_types
}
