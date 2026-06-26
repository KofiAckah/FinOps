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
  description = "Minimum number of On-Demand instances always running in the ASG"
  type        = number
  default     = 1
}
