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

variable "zombie_tag_key" {
  description = "Tag key that marks an instance as a disposable zombie asset eligible for termination"
  type        = string
  default     = "Type"
}

variable "zombie_tag_value" {
  description = "Tag value (for zombie_tag_key) that marks an instance as terminable. Must match the IAM terminate condition."
  type        = string
  default     = "ZombieAsset"
}
