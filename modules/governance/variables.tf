variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 50
}

variable "alert_email" {
  description = "Email address to receive budget and compliance alerts (must confirm the SNS subscription)"
  type        = string
}
