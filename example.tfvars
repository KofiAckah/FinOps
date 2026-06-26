# Copy to terraform.tfvars and fill in. terraform.tfvars is gitignored.
#
#   cp example.tfvars terraform.tfvars

# Email that receives budget alerts. You must click the confirmation link AWS
# SNS sends to this address after `terraform apply`, or no alerts arrive.
alert_email = "you@example.com"

# Optional overrides (defaults shown):
# region                  = "eu-west-1"
# budget_limit_usd        = 50
# asg_desired_capacity    = 3
# on_demand_base_capacity = 1
