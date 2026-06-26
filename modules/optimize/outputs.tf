output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.mixed.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = aws_autoscaling_group.mixed.arn
}

output "launch_template_id" {
  description = "ID of the Launch Template"
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the Launch Template"
  value       = aws_launch_template.app.latest_version
}

output "on_demand_base_capacity" {
  description = "Guaranteed On-Demand instances always running"
  value       = var.on_demand_base_capacity
}

output "spot_instance_types" {
  description = "Instance types available for Spot capacity"
  value       = ["t3.large", "t3a.large"]
}

output "security_group_id" {
  description = "Security group attached to ASG instances"
  value       = aws_security_group.app.id
}
