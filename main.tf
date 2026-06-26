# The "Cost Detective" Audit — single Terraform root.
#
# One backend, one provider, four composable child modules. Deploy order is
# resolved automatically by Terraform's dependency graph; no per-directory
# init/apply juggling.

# Part 1 — the problem: deliberately wasteful "zombie" resources.
module "zombie" {
  source = "./modules/zombie"
  region = var.region
}

# Part 2 — governance: budget + alerts, tagging detection (Config) and
# prevention (IAM deny / SCP simulation).
module "governance" {
  source           = "./modules/governance"
  alert_email      = var.alert_email
  budget_limit_usd = var.budget_limit_usd
}

# Part 1 (solution) — automated, multi-region zombie garbage collector.
module "cleanup" {
  source             = "./modules/cleanup"
  cpu_idle_threshold = var.cpu_idle_threshold
  idle_lookback_days = var.idle_lookback_days
}

# Part 3 — cost-aware architecture: mixed On-Demand + Spot Auto Scaling Group.
module "optimize" {
  source                  = "./modules/optimize"
  asg_min_size            = var.asg_min_size
  asg_max_size            = var.asg_max_size
  asg_desired_capacity    = var.asg_desired_capacity
  on_demand_base_capacity = var.on_demand_base_capacity
}
