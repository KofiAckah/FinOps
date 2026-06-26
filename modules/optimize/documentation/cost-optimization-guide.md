# AWS Cost Optimization — End-to-End Guide

This guide walks through a practical, implementable cost optimization strategy for an AWS environment. It covers the three pillars applied in this project: **identifying waste**, **enforcing governance**, and **architecting for cost efficiency**.

---

## 1. Identify waste — zombie resource audit

Zombie assets are AWS resources that are running but serving no purpose. They are the fastest wins in any cost reduction effort.

### The three most common zombie types

| Resource | Zombie state | Daily cost (approx.) |
|---|---|---|
| EC2 instance (t3.medium) | Running, 0% CPU utilization | ~$1.10/day |
| EBS volume (10 GiB gp3) | `available` — not attached to any instance | ~$0.03/day |
| Elastic IP | Allocated but not associated with a running instance | $0.005/hour |

### How to find them

**AWS Cost Explorer** — navigate to Cost Explorer → filter by service → look for services spending money with no corresponding workload. Unattached EBS and idle EIPs appear under EC2-Other.

**AWS Trusted Advisor** — under the Cost Optimization category, Trusted Advisor flags:
- Idle EC2 instances (< 10% CPU over 14 days)
- Unassociated Elastic IPs
- Underutilized EBS volumes

> Trusted Advisor cost checks require Business or Enterprise support plan. For free accounts, use Cost Explorer or the Boto3 script below.

### Automated cleanup — garbage collector script

The `modules/cleanup` module contains a Lambda function (`garbage_collector.py`) that runs every Sunday at 23:59 UTC via EventBridge and **sweeps every enabled region**. It does the following:

```
For each enabled region:
  1. Describe all EBS volumes where state = "available"   → delete them
  2. Describe all Elastic IPs where AssociationId is null → release them
  3. Describe all running EC2 instances
     └── If tagged Type=ZombieAsset AND older than 7 days:
         └── Pull CloudWatch CPUUtilization (7-day average)
             └── If avg CPU < 5% → terminate the instance
```

Termination is fenced to instances tagged `Type=ZombieAsset` in **both** the code and the Lambda's IAM policy, so it can never terminate an untagged production instance.

**Deploy** (single root for the whole project):
```bash
./scripts/bootstrap-backend.sh   # once
terraform init
terraform apply
```

**Test it immediately (without waiting for Sunday):**
```bash
aws lambda invoke \
  --function-name zombie-garbage-collector \
  --region eu-west-1 \
  response.json && cat response.json
```

---

## 2. Enforce governance — budgets and tagging

Cost visibility requires two things: a spending ceiling and a consistent tagging taxonomy.

### AWS Budget with tiered alerts

A $50/month budget is configured in `governance-arch/` with the following alert tiers:

| Threshold | Type | What it means |
|---|---|---|
| 50% ($25) | Actual | Spend is at the halfway point — monitor closely |
| 70% ($35) | Actual | Approaching limit — review active resources |
| 80% ($40) | Actual | Action required — identify and stop non-essential workloads |
| 80% ($40) | Forecasted | AWS predicts you will breach the budget this month |
| 90% ($45) | Actual | Critical — begin shutting down non-production resources |
| 100% ($50) | Actual | Budget breached |
| 100% ($50) | Forecasted | AWS predicts a breach before month end |

All alerts route to SNS → email. After running `terraform apply` in `governance-arch/`, check your email and confirm the SNS subscription, otherwise alerts are not delivered.

### CostCenter tagging policy

Every EC2 instance must carry a `CostCenter` tag. This enables cost allocation by team or project in Cost Explorer.

Two enforcement layers are in place:

**Detective — AWS Config `REQUIRED_TAGS` rule**

Continuously evaluates all EC2 instances. Instances missing `CostCenter` appear as `NON_COMPLIANT` in the Config dashboard within minutes of launch.

Where to view: AWS Console → Config → Rules → `require-costcenter-tag-ec2` → Resources in scope

**Preventive — IAM Deny policy (SCP simulation)**

An IAM policy attached to `finops-scp-test-user` blocks `ec2:RunInstances` when `CostCenter` is absent or empty. This mirrors what a real AWS Organizations SCP does.

**Test the deny:**
```bash
# Should return UnauthorizedOperation
aws ec2 run-instances \
  --image-id ami-0d64bb532e0502c46 \
  --instance-type t3.micro \
  --count 1 \
  --region eu-west-1 \
  --profile scp-test

# Should succeed
aws ec2 run-instances \
  --image-id ami-0d64bb532e0502c46 \
  --instance-type t3.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=CostCenter,Value=engineering}]' \
  --region eu-west-1 \
  --profile scp-test
```

---

## 3. Optimize architecture — Spot Instances and Auto Scaling

The most significant compute cost reduction comes from replacing On-Demand instances with Spot Instances for stateless, interruption-tolerant workloads.

### Spot vs On-Demand pricing comparison

| Instance type | On-Demand (eu-west-1) | Spot (approx.) | Savings |
|---|---|---|---|
| t3.medium | $0.0416/hr | ~$0.013/hr | ~69% |
| t3.large | $0.0832/hr | ~$0.026/hr | ~69% |
| t3a.large | $0.0752/hr | ~$0.023/hr | ~69% |

For a workload running 3 instances 24/7 for a month:
- **Pure On-Demand (t3.medium):** ~$90/month
- **Mixed (1 On-Demand + 2 Spot t3.large):** ~$50/month
- **Saving: ~44%**

### Mixed Instances Policy — how it works

The ASG in `optimize-arch/main.tf` uses a Mixed Instances Policy:

```
Auto Scaling Group (min: 1, max: 5, desired: 3)
│
├── On-Demand base: 1 instance (always t3.medium)
│   └── Guaranteed capacity — never interrupted
│
└── Spot scaling: 2 instances (t3.large or t3a.large)
    └── AWS picks whichever pool has the most available capacity
        (capacity-optimized strategy = lowest interruption rate)
```

**Why three instance types?**

Spot capacity comes from unused AWS capacity. By specifying multiple instance types (`t3.large` and `t3a.large`), the ASG can draw from more capacity pools — reducing the chance that all your Spot instances get reclaimed simultaneously.

**What happens during a Spot interruption?**

AWS gives a 2-minute warning via instance metadata and EventBridge before reclaiming a Spot instance. The ASG automatically replaces the interrupted instance using whichever pool has capacity at that moment. For stateless workloads (no local state), this is seamless.

### Auto Scaling policies

Two CloudWatch alarms drive scaling:

| Alarm | Condition | Action |
|---|---|---|
| `finops-asg-high-cpu` | Avg CPU > 70% for 2 minutes | Add 1 instance (Spot first) |
| `finops-asg-low-cpu` | Avg CPU < 20% for 3 minutes | Remove 1 instance |

Scale-in has a longer cooldown (300s vs 120s) to prevent thrashing — you want to be confident the load has dropped before removing capacity.

### Deploy the optimized ASG

The ASG is part of the single Terraform root, so it deploys with the rest of the project:

```bash
terraform apply
```

**Verify the instance mix after deployment** (query EC2 directly so the Spot lifecycle is visible):
```bash
aws ec2 describe-instances --region eu-west-1 \
  --filters Name=tag:aws:autoscaling:groupName,Values=finops-mixed-instances-asg \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Lifecycle:InstanceLifecycle}' \
  --output table
```

You should see 1 instance with `Lifecycle: None` (On-Demand base) and 2 with `Lifecycle: spot`.

---

## 4. Ongoing cost hygiene — recommended practices

### Weekly
- Review Cost Explorer for unexpected spikes — filter by service and tag
- Check the garbage collector Lambda CloudWatch logs (`/aws/lambda/zombie-garbage-collector`) for what was cleaned up

### Monthly
- Review AWS Config compliance dashboard — fix any `NON_COMPLIANT` tagged resources
- Review ASG scaling history — if desired capacity is always at max, consider rightsizing the max or the instance types
- Compare Spot interruption rate in EC2 → Spot Requests → Interruptions tab

### Before any new deployment
- Ensure all EC2 resources carry the `CostCenter` tag at launch (use `--tag-specifications` in CLI or the launch template tag)
- Check AWS Pricing Calculator for estimated monthly cost before provisioning large instances
- Prefer Spot for any batch, dev, or stateless workload; reserve On-Demand for databases, stateful services, or jobs that cannot tolerate interruption

### Cost Explorer filters to bookmark
- Group by: **Tag → CostCenter** — see spend per team
- Group by: **Purchase Option** — see On-Demand vs Spot ratio
- Group by: **Usage Type** — identify `EBS:VolumeUsage` and `ElasticIP:IdleAddress` charges
