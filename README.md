# The Cost Detective Audit

**Scenario:** You have inherited an AWS account from a previous team that was reckless with spending. Your budget is tight. Identify waste, implement governance, and architect a cost-aware solution.

---

## Project Structure

```
FinOps/
├── zombie-arch/                  # Part 1 — Wasteful resource simulation
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── cleanup/                      # Part 1 — Automated garbage collector
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── lambda/
│       └── garbage_collector.py
│
├── governance-arch/              # Part 2 — Budgets, alerts, tagging policy
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── documentation/
│       └── policies/
│           ├── scp-deny-untagged.json
│           └── tagging-policy.md
│
├── optimize-arch/                # Part 3 — Spot + On-Demand ASG
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── documentation/
│       └── cost-optimization-guide.md
│
└── Assets/                       # Screenshots from live AWS console
```

---

## Part 1 — Analysis and Cleanup

### Zombie resources deployed

Three deliberately wasteful resources were provisioned in `eu-west-1` using `zombie-arch/` to simulate a neglected account:

| Resource | Name | Details | Why it wastes money |
|---|---|---|---|
| EC2 Instance | `zombie-idle-ec2` | t3.medium, Amazon Linux 2023 | Running with 0% CPU — paying for idle compute |
| EBS Volume | `zombie-unattached-ebs` | 10 GiB gp3, `eu-west-1a` | `Available` state — not attached to any instance |
| Elastic IP | `zombie-unassociated-eip` | `79.125.119.62` | Allocated but not associated — AWS charges for idle EIPs |

### Evidence — AWS Console screenshots

**Cost and Usage dashboard**

The billing dashboard at the time of deployment showed $0.03 current-month spend across Config, Tax, S3, GuardDuty, and KMS — confirming the account was essentially idle before the zombie resources were introduced.

![Cost and Usage](Assets/Screenshot%20from%202026-05-26%2015-37-54.png)

---

**Trusted Advisor**

Trusted Advisor was checked for cost optimization findings. The account is on the free support tier, which limits access to the full check set. The RDS cost optimization check was visible but the cost-specific EC2/EIP idle checks require Business or Enterprise support.

![Trusted Advisor](Assets/Screenshot%20from%202026-05-26%2015-57-01.png)

---

**Unattached EBS Volume confirmed in console**

Volume `vol-04a67d91f5f0602a7` (`zombie-unattached-ebs`) is 10 GiB gp3, in `eu-west-1a`. Volume state is **Available** — meaning it is not attached to any instance and is accumulating storage charges with no workload benefit.

![Unattached EBS Volume](Assets/Screenshot%20from%202026-05-26%2016-00-12.png)

---

**Unassociated Elastic IP confirmed in console**

EIP `79.125.119.62` (allocation ID `eipalloc-07729e84729b501d0`) is allocated to the VPC but has no Association ID, no Associated Instance ID, and no Network Interface. AWS charges $0.005/hour for every idle EIP.

![Unassociated EIP](Assets/Screenshot%20from%202026-05-26%2016-04-30.png)

---

### Automated garbage collector

The `cleanup/` module contains a Lambda function that automatically removes zombie resources on a weekly schedule. It is not scoped to tagged resources — it evaluates the entire account.

**What it deletes:**

| Target | Detection logic | Action |
|---|---|---|
| EBS volumes | `state == available` | `DeleteVolume` |
| Elastic IPs | `AssociationId` absent | `ReleaseAddress` |
| EC2 instances | Avg CPU < 5% over 7 days (via CloudWatch) | `TerminateInstances` |

**Schedule:** EventBridge rule — every Sunday at 23:59 UTC (`cron(59 23 ? * SUN *)`)

**Safety guard:** Instances younger than 7 days are skipped — not enough CloudWatch data to make a fair idle determination.

**Deploy:**
```bash
cd cleanup
terraform init
terraform apply
```

**Run immediately (without waiting for Sunday):**
```bash
aws lambda invoke \
  --function-name zombie-garbage-collector \
  --region eu-west-1 \
  response.json && cat response.json
```

**View logs:**
```bash
aws logs tail /aws/lambda/zombie-garbage-collector --follow --region eu-west-1
```

---

## Part 2 — Governance

### AWS Budget — $50/month with tiered alerts

Configured in `governance-arch/main.tf`. Alerts fire via SNS and direct email to `joel.ackah@amalitech.com`.

| Threshold | Type | Meaning |
|---|---|---|
| 50% ($25) | Actual | Halfway — monitor |
| 70% ($35) | Actual | Approaching limit — review resources |
| 80% ($40) | Actual | Action required |
| 80% ($40) | Forecasted | AWS predicts a breach this month |
| 90% ($45) | Actual | Critical — shut down non-production |
| 100% ($50) | Actual | Budget breached |
| 100% ($50) | Forecasted | Breach predicted before month end |

> After `terraform apply`, confirm the SNS email subscription from your inbox. Alerts are not delivered until the subscription is confirmed.

### CostCenter tagging policy

Every EC2 instance must carry a `CostCenter` tag. Two enforcement layers are in place:

#### Detective layer — AWS Config `REQUIRED_TAGS`

`aws_config_config_rule.require_costcenter_tag` continuously evaluates all EC2 instances. Any instance missing the `CostCenter` tag is flagged as `NON_COMPLIANT` in the Config dashboard within minutes of launch.

**Where to view:** AWS Console → Config → Rules → `require-costcenter-tag-ec2`

This rule **does not block** instance launches — it flags violations after the resource already exists.

#### Preventive layer — IAM Deny policy (SCP simulation)

`aws_iam_policy.deny_untagged_ec2` is attached to `finops-scp-test-user` and blocks `ec2:RunInstances` when the `CostCenter` tag is absent or empty. This produces the same `UnauthorizedOperation` API denial that a real AWS Organizations SCP would — without requiring an AWS Organization.

The actual SCP JSON is documented at `governance-arch/documentation/policies/scp-deny-untagged.json` for use when the account is part of an Organization.

**Test the deny (using the test user profile):**

```bash
# Configure the test user profile after terraform apply
aws configure --profile scp-test
# Enter the access key ID and secret from terraform output

# Test 1 — No tags → DENIED
aws ec2 run-instances \
  --image-id ami-0d64bb532e0502c46 \
  --instance-type t3.micro \
  --count 1 \
  --region eu-west-1 \
  --profile scp-test

# Test 2 — Empty CostCenter → DENIED
aws ec2 run-instances \
  --image-id ami-0d64bb532e0502c46 \
  --instance-type t3.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=CostCenter,Value=}]' \
  --region eu-west-1 \
  --profile scp-test

# Test 3 — Valid CostCenter → ALLOWED
aws ec2 run-instances \
  --image-id ami-0d64bb532e0502c46 \
  --instance-type t3.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=CostCenter,Value=engineering}]' \
  --region eu-west-1 \
  --profile scp-test
```

Expected output for denied calls:
```
An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation.
```

**Deploy governance:**
```bash
cd governance-arch
terraform init
terraform apply

# Retrieve test user credentials
terraform output scp_test_user_access_key_id
terraform output -raw scp_test_user_secret_access_key
```

---

## Part 3 — Optimization Architecture

### Auto Scaling Group with Mixed Instances Policy

Deployed in `optimize-arch/`. Combines a guaranteed On-Demand base with Spot Instances for all additional capacity — targeting stateless, interruption-tolerant workloads.

**Instance composition (desired capacity = 3):**

| Role | Instance type | Purchase type | Count |
|---|---|---|---|
| Base | t3.medium | On-Demand | 1 (always running) |
| Scale-out | t3.large | Spot | up to 4 |
| Scale-out fallback | t3a.large | Spot | up to 4 |

**Key configuration decisions:**

- `on_demand_base_capacity = 1` — one instance is always On-Demand, guaranteeing baseline availability even during Spot market disruption
- `on_demand_percentage_above_base_capacity = 0` — every instance provisioned beyond the base 1 is Spot
- `spot_allocation_strategy = capacity-optimized` — AWS selects the Spot pool with the most available capacity, minimising interruption rate
- Two Spot instance types (`t3.large`, `t3a.large`) — diversifying across pools further reduces the risk of simultaneous interruptions

**Cost comparison (eu-west-1, approximate):**

| Configuration | Monthly cost (3 instances, 24/7) |
|---|---|
| 3x t3.medium On-Demand | ~$90 |
| 1x t3.medium On-Demand + 2x t3.large Spot | ~$50 |
| Saving | ~44% |

**Auto-scaling triggers:**

| Alarm | Condition | Action | Cooldown |
|---|---|---|---|
| `finops-asg-high-cpu` | Avg CPU > 70% for 2 min | +1 instance (Spot first) | 120s |
| `finops-asg-low-cpu` | Avg CPU < 20% for 3 min | −1 instance | 300s |

The scale-in cooldown is longer (300s) to prevent thrashing — the ASG waits to confirm load has genuinely dropped before removing capacity.

**Each instance runs a lightweight HTTP server** that returns its own instance ID, instance type, and lifecycle (`spot` or `on-demand`) — useful for visually confirming the purchase mix during a live walkthrough.

**Deploy:**
```bash
cd optimize-arch
terraform init
terraform apply
```

**Verify instance mix:**
```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names finops-mixed-instances-asg \
  --region eu-west-1 \
  --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,Type:InstanceType,Market:InstancePurchaseOption}' \
  --output table
```

For the full end-to-end cost optimization guide including ongoing hygiene practices, see [`optimize-arch/documentation/cost-optimization-guide.md`](optimize-arch/documentation/cost-optimization-guide.md).

---

## Deployment Order

Each module is an independent Terraform root — deploy in this order so dependencies (IAM, Config recorder) are available before dependent modules run:

```bash
# 1. Zombie resources (the problem)
cd zombie-arch && terraform init && terraform apply

# 2. Governance (budget + tagging enforcement)
cd ../governance-arch && terraform init && terraform apply

# 3. Automated cleanup (the solution to Part 1)
cd ../cleanup && terraform init && terraform apply

# 4. Optimized architecture
cd ../optimize-arch && terraform init && terraform apply
```

## Tear down

```bash
for dir in optimize-arch cleanup governance-arch zombie-arch; do
  cd /home/user/FinOps/$dir && terraform destroy -auto-approve
done
```

---

## Requirements

- Terraform >= 1.3.0
- AWS provider 6.25.0
- AWS CLI configured with sufficient IAM permissions (EC2, Lambda, Budgets, Config, Organizations read, SNS, CloudWatch, IAM)
- Python 3.12 (used by the Lambda runtime — no local dependency required)
