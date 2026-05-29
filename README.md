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
├── cleanup/                      # Part 1 — Automated garbage collector Lambda
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

---

### Evidence — AWS Console screenshots

#### Cost before zombie resources

At the start of the audit, the account spent only $0.03 for the month — driven by Config, Tax, S3, and GuardDuty. This is the baseline.

![Cost before zombie resources](Assets/Screenshot%20from%202026-05-26%2015-37-54.png)

---

#### Trusted Advisor

Trusted Advisor was checked for cost optimization findings. The account is on the free support tier, which limits access to the full check set — cost-specific checks for idle EC2 and EIPs require Business or Enterprise support.

![Trusted Advisor](Assets/Screenshot%20from%202026-05-26%2015-57-01.png)

---

#### Unattached EBS Volume in the console

Volume `vol-04a67d91f5f0602a7` (`zombie-unattached-ebs`) is 10 GiB gp3, in `eu-west-1a`. **Volume state: Available** — not attached to any instance, accumulating storage charges with no workload benefit.

![Unattached EBS Volume](Assets/Screenshot%20from%202026-05-26%2016-00-12.png)

---

#### Unassociated Elastic IP in the console

EIP `79.125.119.62` (allocation `eipalloc-07729e84729b501d0`) has no Association ID, no Associated Instance ID, and no Network Interface. AWS charges $0.005/hour for every idle EIP.

![Unassociated EIP](Assets/Screenshot%20from%202026-05-26%2016-04-30.png)

---

#### Cost impact — after zombie resources ran

After the zombie resources ran for approximately 37 hours, monthly spend jumped from **$0.03 to $1.57** — a 2,517% increase. The breakdown shows EC2 Compute ($0.98) as the dominant driver, followed by VPC/networking charges ($0.23) from the idle EIP and EC2-Other ($0.09) from the EBS volume.

![Cost after zombie resources](Assets/Screenshot%20from%202026-05-28%2011-00-33.png)

---

#### Billing line-item breakdown

The AWS Bills page confirms the exact charges: the `zombie-idle-ec2` t3.medium instance ran for **37 hours at $0.0456/hr = $1.69** (slightly offset by an EC2 Savings Plan discount of -$0.03). The unattached EBS volume contributed **$0.16** for 1.828 GB-months of gp3 storage.

![Billing breakdown](Assets/Screenshot%20from%202026-05-28%2011-02-27.png)

---

### Automated garbage collector

The `cleanup/` module contains a Lambda function that automatically removes zombie resources on a weekly schedule. It evaluates the **entire account**, not just tagged resources.

**What it deletes:**

| Target | Detection logic | Action |
|---|---|---|
| EBS volumes | `state == available` | `DeleteVolume` |
| Elastic IPs | `AssociationId` absent | `ReleaseAddress` |
| EC2 instances | Avg CPU < 5% over 7 days (CloudWatch) | `TerminateInstances` |

**Schedule:** EventBridge — every Sunday at 23:59 UTC (`cron(59 23 ? * SUN *)`)

**Safety guard:** Instances younger than 7 days are skipped — insufficient CloudWatch data to make a fair idle determination.

**Deploy:**
```bash
cd cleanup
terraform init
terraform apply
```

**Run immediately without waiting for Sunday:**
```bash
aws lambda invoke \
  --function-name zombie-garbage-collector \
  --region eu-west-1 \
  response.json && cat response.json
```

---

## Part 2 — Governance

### AWS Budget — $50/month with tiered alerts

Configured in `governance-arch/main.tf`. All alerts route to SNS and direct email (`joel.ackah@amalitech.com`).

| Threshold | Type | Meaning |
|---|---|---|
| 50% ($25) | Actual | Halfway — monitor |
| 70% ($35) | Actual | Approaching limit — review resources |
| 80% ($40) | Actual | Action required |
| 80% ($40) | Forecasted | AWS predicts a breach this month |
| 90% ($45) | Actual | Critical — shut down non-production |
| 100% ($50) | Actual | Budget breached |
| 100% ($50) | Forecasted | Breach predicted before month end |

> After `terraform apply`, confirm the SNS email subscription from your inbox. Alerts are not delivered until confirmed.

#### Budget alerts configured in AWS Console

All seven alert thresholds are active in the Budgets dashboard. The screenshot shows each notification defined with its threshold, type (actual vs forecasted), and threshold amount against the $50 budget.

![Budget alerts configured](Assets/Screenshot%20from%202026-05-28%2016-14-32.png)

---

### CostCenter tagging policy

Every EC2 instance must carry a `CostCenter` tag for cost attribution. Two enforcement layers are in place.

---

#### Detective layer — AWS Config `REQUIRED_TAGS`

`aws_config_config_rule.require_costcenter_tag` continuously evaluates all EC2 instances. Any instance missing `CostCenter` is flagged **NON_COMPLIANT** in the Config dashboard within minutes of launch.

**Where to view:** AWS Console → Config → Rules → `require-costcenter-tag-ec2`

This rule **does not block** launches — it flags violations after the resource already exists.

#### AWS Config — NON_COMPLIANT resources detected

The Config Resource Inventory filtered to NON_COMPLIANT resources shows the zombie assets flagged: the unattached EBS volume, S3 bucket, and multiple EC2 instances (including `zombie-idle-ec2`) are all marked non-compliant because they lack the required `CostCenter` tag.

![Config NON_COMPLIANT resources](Assets/Screenshot%20from%202026-05-28%2016-41-35.png)

---

#### Preventive layer — IAM Deny policy (SCP simulation)

`aws_iam_policy.deny_untagged_ec2` is attached to `finops-scp-test-user` and blocks `ec2:RunInstances` when `CostCenter` is absent or empty. This produces the same `UnauthorizedOperation` API denial that a real AWS Organizations SCP would — without requiring an AWS Organization.

The actual SCP JSON is at `governance-arch/documentation/policies/scp-deny-untagged.json` for use when the account is part of an Organization.

#### IAM test user configured with both policies

The `finops-scp-test-user` IAM user is created with two policies attached directly:
- `AmazonEC2FullAccess` (AWS managed) — allows the user to attempt EC2 operations
- `finops-deny-untagged-ec2` (Customer managed) — denies `RunInstances` when `CostCenter` is missing or empty

The access key is active and was used for all CLI tests below.

![finops-scp-test-user IAM user](Assets/Screenshot%20from%202026-05-29%2010-22-17.png)

---

#### Test 1 — Launch without tags → DENIED

Attempting to launch an EC2 instance through the console without providing a `CostCenter` tag results in an immediate **"Instance launch failed"** error. The launch log shows the request was received and immediately rejected with an encoded `UnauthorizedOperation` authorization failure message.

![Launch failed — no tags](Assets/Screenshot%20from%202026-05-29%2010-43-47.png)

---

#### Test 2 — Launch with invalid/empty CostCenter → DENIED

A second attempt to launch — this time with a `CostCenter` tag provided but with an empty or insufficient value — is also blocked. The same `UnauthorizedOperation` error banner appears, confirming that the deny policy catches both the null-tag and empty-string cases.

![Launch failed — empty CostCenter](Assets/Screenshot%20from%202026-05-29%2010-46-12.png)

---

#### Test 3 — Launch with valid CostCenter → ALLOWED

Providing a valid `CostCenter` value (`FinOps`) allows the instance to launch successfully. The EC2 Instances list confirms the new instance (`i-091df5047bf633e9e`, named `NoTag`) is initializing alongside the existing `zombie-idle-ec2`. The Tags tab for the new instance shows `CostCenter=FinOps` — the policy allowed the request because the required tag was present with a non-empty value.

![Launch succeeded — valid CostCenter](Assets/Screenshot%20from%202026-05-29%2010-49-05.png)

![Launch succeeded — valid CostCenter](Assets/Screenshot%20from%202026-05-29%2010-51-31.png)

---

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

Deployed in `optimize-arch/`. Combines a guaranteed On-Demand base with Spot Instances for all additional capacity, targeting stateless, interruption-tolerant workloads.

**Instance composition (desired capacity = 3):**

| Role | Instance type | Purchase type | Always running |
|---|---|---|---|
| Base | t3.medium | On-Demand | Yes — guaranteed |
| Scale-out | t3.large | Spot | Up to 4 additional |
| Scale-out fallback | t3a.large | Spot | Up to 4 additional |

**Cost comparison (eu-west-1, approximate):**

| Configuration | Monthly cost (3 instances, 24/7) |
|---|---|
| 3x t3.medium On-Demand | ~$90 |
| 1x t3.medium On-Demand + 2x t3.large Spot | ~$50 |
| Saving | ~44% |

**Auto-scaling triggers:**

| Alarm | Condition | Action | Cooldown |
|---|---|---|---|
| `finops-asg-high-cpu` | Avg CPU > 70% for 2 min | +1 instance | 120s |
| `finops-asg-low-cpu` | Avg CPU < 20% for 3 min | −1 instance | 300s |

---

#### ASG created and active in AWS Console

The `finops-mixed-instances-asg` Auto Scaling Group is live in `eu-west-1`. The Capacity overview confirms the desired, minimum, and maximum capacity settings. The Details tab shows the associated Launch Template and the AZ distribution across `eu-west-1a`, `eu-west-1b`, and `eu-west-1c`.

![ASG created](Assets/Screenshot%20from%202026-05-29%2010-51-31.png)

---

#### Mixed Instances Policy — instance types and purchase options

The ASG Instance type requirements section confirms all three instance types are registered: `t3.medium` (2 vCPUs, 4 GiB), `t3.large` (2 vCPUs, 8 GiB), and `t3a.large` (2 vCPUs, 8 GiB). The Instance purchase options section shows the On-Demand base capacity alongside the Spot allocation strategy set to **capacity-optimized** — AWS selects the Spot pool with the most available capacity, minimising interruption rate.

![ASG instance types and purchase options](Assets/Screenshot%20from%202026-05-29%2014-42-48.png)

---

#### ASG allocation strategies confirmed

The allocation strategies section confirms:
- **On-Demand allocation strategy** is configured for the base capacity
- **Spot allocation strategy: capacity-optimized** — maximises availability from the highest-capacity Spot pool
- **Capacity rebalance** is enabled — the ASG proactively replaces Spot instances that receive an interruption notice before they are reclaimed

![ASG allocation strategies](Assets/Screenshot%20from%202026-05-29%2014-42-58.png)

---

**Deploy:**
```bash
cd optimize-arch
terraform init
terraform apply
```

**Verify instance mix after deployment:**
```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names finops-mixed-instances-asg \
  --region eu-west-1 \
  --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,Type:InstanceType,Market:InstancePurchaseOption}' \
  --output table
```

For the full end-to-end cost optimization guide see [`optimize-arch/documentation/cost-optimization-guide.md`](optimize-arch/documentation/cost-optimization-guide.md).

---

## Deployment Order

Each module is an independent Terraform root. Deploy in this order:

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

## Tear Down

```bash
for dir in optimize-arch cleanup governance-arch zombie-arch; do
  cd /path/to/FinOps/$dir && terraform destroy -auto-approve
done
```

---

## Requirements

- Terraform >= 1.3.0
- AWS provider 6.25.0
- AWS CLI configured with sufficient IAM permissions (EC2, Lambda, Budgets, Config, SNS, CloudWatch, IAM)
- Python 3.12 (Lambda runtime — no local dependency required)
