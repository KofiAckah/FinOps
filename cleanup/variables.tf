variable "region" {
  description = "AWS region where the cleanup Lambda runs"
  type        = string
  default     = "eu-west-1"
}

variable "cpu_idle_threshold" {
  description = "Average CPU % below which a running EC2 instance is considered idle"
  type        = number
  default     = 5
}

variable "idle_lookback_days" {
  description = "Number of days of CloudWatch data to evaluate for EC2 idle detection"
  type        = number
  default     = 7
}
