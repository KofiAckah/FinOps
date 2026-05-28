variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 50
}

variable "alert_email" {
  description = "Email address to receive budget and compliance alerts"
  type        = string
  default     = "joel.ackah@amalitech.com"
}
