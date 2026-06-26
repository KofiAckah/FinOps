variable "region" {
  description = "AWS region for all regional resources"
  type        = string
  default     = "eu-west-1"
}

# ─── Governance ───────────────────────────────────────────────────────────────

variable "alert_email" {
  description = "Email address that receives budget alerts (you must confirm the SNS subscription email after apply)"
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 50
}

# ─── Cleanup / garbage collector ───────────────────────────────────────────────

variable "cpu_idle_threshold" {
  description = "Average CPU % below which a running EC2 instance is considered idle"
  type        = number
  default     = 5
}

variable "idle_lookback_days" {
  description = "Days of CloudWatch history evaluated for EC2 idle detection"
  type        = number
  default     = 7
}

# ─── Optimization ASG ──────────────────────────────────────────────────────────

variable "asg_min_size" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 5
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the ASG"
  type        = number
  default     = 3
}

variable "on_demand_base_capacity" {
  description = "Guaranteed On-Demand instances always running in the ASG"
  type        = number
  default     = 1
}
