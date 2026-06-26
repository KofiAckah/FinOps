# The Cost Detective Audit

**Scenario:** You have inherited an AWS account from a previous team that was reckless with spending. Your budget is tight. Identify waste, implement governance, and architect a cost-aware solution.

---

## Project Structure

A **single Terraform root** composes four child modules behind **one S3 remote backend**. There is one `terraform init` / `terraform apply` for the whole project — Terraform resolves the deploy order from the dependency graph.

```
FinOps/
├── backend.tf                    # S3 remote state + native lockfile (no DynamoDB)
├── providers.tf                  # AWS + archive providers, default_tags
├── main.tf                       # composes the four modules
├── variables.tf / outputs.tf     # root inputs & surfaced outputs
├── example.tfvars                # copy to terraform.tfvars
│
├── modules/
│   ├── zombie/                   # Part 1 — wasteful resource simulation
│   ├── cleanup/                  # Part 1 — multi-region garbage-collector Lambda
│   │   └── lambda/garbage_collector.py
│   ├── governance/               # Part 2 — budget, alerts, tagging policy
│   │   └── documentation/policies/{scp-deny-untagged.json, tagging-policy.md}
│   └── optimize/                 # Part 3 — Spot + On-Demand mixed ASG
│       └── documentation/cost-optimization-guide.md
│
├── tests/                        # pytest unit tests for the garbage collector
├── scripts/bootstrap-backend.sh  # creates the S3 state bucket (run once)
├── .github/workflows/ci.yml      # fmt + validate + pytest on every push/PR
└── Assets/                       # screenshots from the live AWS console
```

> **What changed from the first submission (73%, redo):** consolidated 4 separate Terraform roots with local state into one root + child modules on an S3 backend; scoped the Lambda's `TerminateInstances` to `Type=ZombieAsset`; made the garbage collector multi-region; removed duplicate budget emails; stopped writing the IAM secret key into state; added unit tests + CI; and `.gitignore`d the Lambda zip. See [Review Response](#how-the-first-round-feedback-was-addressed).

---

## Deploy

```bash
# 0. Authenticate (this account uses the NSPAccount profile)
export AWS_PROFILE=NSPAccount

# 1. Create the remote-state bucket once
./scripts/bootstrap-backend.sh

# 2. Provide your alert email
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars        # set alert_email

# 3. Init against the S3 backend, then apply everything
terraform init
terraform apply
```

After apply, **confirm the SNS subscription email** AWS sends to `alert_email`, or budget alerts will not be delivered.

### Tear down

```bash
terraform destroy
```

> **Org constraint:** this sandbox sits under an AWS Organizations SCP that denies `config:StopConfigurationRecorder` and `config:DeleteConfigRule`. `terraform destroy` will therefore fail to remove `aws_config_configuration_recorder` and the `require-costcenter-tag-ec2` rule — leave them in place (an org admin owns them) or `terraform state rm` those two addresses before destroying the rest. This is why those resources survived the first teardown.

---

## Part 1 — Analysis and Cleanup

### Zombie resources deployed (`modules/zombie`)

Three deliberately wasteful resources are provisioned in `eu-west-1` to simulate a neglected account. All are tagged `Type=ZombieAsset` so the garbage collector is permitted to reap them.

| Resource | Name | Details | Why it wastes money |
|---|---|---|---|
| EC2 Instance | `zombie-idle-ec2` | t3.medium, Amazon Linux 2023 | Running at 0% CPU — paying for idle compute |
| EBS Volume | `zombie-unattached-ebs` | 10 GiB gp3, `eu-west-1a` | `Available` — not attached to any instance |
| Elastic IP | `zombie-unassociated-eip` | allocated EIP | Not associated — AWS charges for idle EIPs |

### Evidence — AWS Console screenshots

#### Cost before zombie resources
Baseline monthly spend was **$0.03** (Config, Tax, S3, GuardDuty).
![Cost before zombie resources](Assets/Screenshot%20from%202026-05-26%2015-37-54.png)

#### Trusted Advisor
Account is on the free support tier, which limits the cost-specific checks (idle EC2, unassociated EIPs need Business/Enterprise support).
![Trusted Advisor](Assets/Screenshot%20from%202026-05-26%2015-57-01.png)

#### Unattached EBS volume
10 GiB gp3 in `eu-west-1a`, **state: Available** — accumulating storage charges with no workload.
![Unattached EBS Volume](Assets/Screenshot%20from%202026-05-26%2016-00-12.png)

#### Unassociated Elastic IP
No Association ID, no instance, no ENI — AWS charges $0.005/hour for idle EIPs.
![Unassociated EIP](Assets/Screenshot%20from%202026-05-26%2016-04-30.png)

#### Cost impact — after the zombies ran
After ~37 hours, monthly spend jumped from **$0.03 → $1.57** (a 2,517% increase). EC2 Compute ($0.98) dominates, then VPC/networking ($0.23) from the idle EIP and EC2-Other ($0.09) from the EBS volume.
![Cost after zombie resources](Assets/Screenshot%20from%202026-05-28%2011-00-33.png)

#### Billing line-item breakdown
The t3.medium ran **37 hrs at $0.0456/hr = $1.69** (offset by a -$0.03 Savings Plan discount); the EBS volume added **$0.16** for 1.828 GB-months of gp3.
![Billing breakdown](Assets/Screenshot%20from%202026-05-28%2011-02-27.png)

### Automated garbage collector (`modules/cleanup`)

A Python 3.12 Lambda runs every Sunday at 23:59 UTC (EventBridge) and **sweeps every enabled region**.

| Target | Detection logic | Action |
|---|---|---|
| EBS volumes | `state == available` | `DeleteVolume` |
| Elastic IPs | `AssociationId` absent | `ReleaseAddress` |
| EC2 instances | **tagged `Type=ZombieAsset`** AND age ≥ 7 days AND avg CPU < 5% over 7 days | `TerminateInstances` |

**Safety design (defense in depth):**
- Termination requires the `Type=ZombieAsset` tag — enforced **both** in the Lambda code *and* in its IAM policy (`ec2:TerminateInstances` is conditioned on `ec2:ResourceTag/Type = ZombieAsset`). A logic regression still cannot terminate an untagged production instance.
- Instances younger than the 7-day lookback window are skipped — insufficient CloudWatch history to judge idleness fairly.

**Run on demand (don't wait for Sunday):**
```bash
aws lambda invoke --function-name zombie-garbage-collector \
  --region eu-west-1 response.json && cat response.json
```

**Unit tests** for the detection logic live in `tests/` — see [Testing](#testing).

---

## Part 2 — Governance (`modules/governance`)

### AWS Budget — $50/month with tiered alerts

Seven thresholds, all routed **through SNS only** (the SNS topic holds one confirmed email subscription, so each alert sends exactly one email — no duplicates).

| Threshold | Type | Meaning |
|---|---|---|
| 50% / 70% / 80% / 90% / 100% | Actual | Escalating spend warnings |
| 80% / 100% | Forecasted | AWS predicts a breach this month |

![Budget alerts configured](Assets/Screenshot%20from%202026-05-28%2016-14-32.png)

### CostCenter tagging policy — two enforcement layers

**Detective — AWS Config `REQUIRED_TAGS`** (`require-costcenter-tag-ec2`): continuously flags any EC2 instance missing `CostCenter` as **NON_COMPLIANT**. Reactive — it does not block the launch.
![Config NON_COMPLIANT resources](Assets/Screenshot%20from%202026-05-28%2016-41-35.png)

**Preventive — IAM Deny policy (SCP simulation):** `finops-deny-untagged-ec2`, attached to `finops-scp-test-user`, blocks `ec2:RunInstances` when `CostCenter` is absent or empty — the same `UnauthorizedOperation` a real Organizations SCP produces. The portable SCP JSON is at [`modules/governance/documentation/policies/scp-deny-untagged.json`](modules/governance/documentation/policies/scp-deny-untagged.json).

> **Access keys are not created by Terraform** (that would write the secret into state). Mint a short-lived key out-of-band for the deny tests, then delete it:
> ```bash
> aws iam create-access-key --user-name finops-scp-test-user
> # ...run tests...
> aws iam delete-access-key --user-name finops-scp-test-user --access-key-id <id>
> ```

#### Tagging-policy test cases

| Test | Tags | Result |
|---|---|---|
| 1 | none | **DENIED** ([screenshot](Assets/Screenshot%20from%202026-05-29%2010-43-47.png)) |
| 2 | `CostCenter=` (empty) | **DENIED** ([screenshot](Assets/Screenshot%20from%202026-05-29%2010-46-12.png)) |
| 3 | `CostCenter=FinOps` | **ALLOWED** ([screenshot](Assets/Screenshot%20from%202026-05-29%2010-49-05.png)) |

![IAM test user with both policies](Assets/Screenshot%20from%202026-05-29%2010-22-17.png)

Full policy breakdown, attachment guidance, and break-glass procedures: [`modules/governance/documentation/policies/tagging-policy.md`](modules/governance/documentation/policies/tagging-policy.md).

---

## Part 3 — Optimization Architecture (`modules/optimize`)

### Mixed-Instances Auto Scaling Group

A guaranteed On-Demand base plus Spot for all scale-out, targeting stateless, interruption-tolerant workloads.

| Role | Instance type | Purchase | Notes |
|---|---|---|---|
| Base | t3.medium | On-Demand | 1 always running |
| Scale-out | t3.large | Spot | capacity-optimized |
| Scale-out fallback | t3a.large | Spot | second pool for availability |

**Cost comparison (eu-west-1, 3 instances 24/7):** 3× t3.medium On-Demand ≈ **$90/mo** vs 1× On-Demand + 2× Spot ≈ **$50/mo** → **~44% saving**.

**Auto-scaling:** scale out at avg CPU > 70% (2 min); scale in at avg CPU < 20% (3 min, longer cooldown to avoid thrashing). Capacity rebalancing replaces Spot instances before reclamation.

![ASG created](Assets/Screenshot%20from%202026-05-29%2010-51-31.png)
![ASG instance types and purchase options](Assets/Screenshot%20from%202026-05-29%2014-42-48.png)
![ASG allocation strategies](Assets/Screenshot%20from%202026-05-29%2014-42-58.png)

**Verify the live On-Demand vs Spot mix** (query EC2 directly — `InstanceLifecycle` is `spot` for Spot and absent/`None` for On-Demand):
```bash
aws ec2 describe-instances --region eu-west-1 \
  --filters Name=tag:aws:autoscaling:groupName,Values=finops-mixed-instances-asg \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Lifecycle:InstanceLifecycle,AZ:Placement.AvailabilityZone}' \
  --output table
```

Expected: one instance with `Lifecycle: None` (the On-Demand base) and two with `Lifecycle: spot`.

End-to-end guide: [`modules/optimize/documentation/cost-optimization-guide.md`](modules/optimize/documentation/cost-optimization-guide.md).

---

## Testing

Logic in the garbage collector (idle detection, age guard, tag gate, multi-region discovery) is covered by `pytest` unit tests using mocked boto3 clients — no AWS calls, no credentials.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r tests/requirements.txt
pytest -v
```

The same suite plus `terraform fmt -check` and `terraform validate` run on every push/PR via [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

---

## How the first-round feedback was addressed

| Review gap | Fix |
|---|---|
| No remote backend; 4 local state files | Single S3 backend (`backend.tf`) with native lockfile; bootstrap script |
| 4 separate root modules | One root composing 4 child modules under `modules/` |
| Lambda `TerminateInstances` on `Resource="*"` | Conditioned on `ec2:ResourceTag/Type=ZombieAsset` (IAM **and** code) |
| Duplicate budget emails (SNS + direct) | Removed `subscriber_email_addresses`; SNS-only delivery |
| Access key secret in state | `aws_iam_access_key` removed; keys minted out-of-band |
| Single-region garbage collector | Iterates all enabled regions via `describe_regions` |
| `*.zip` committed | `.gitignore`d and removed (`archive_file` regenerates it) |
| Testing 2/5 | pytest unit suite + GitHub Actions CI |

---

## Requirements

- Terraform >= 1.11.0 (S3 backend native locking), AWS provider 6.25.0
- AWS CLI configured (`AWS_PROFILE=NSPAccount`) with EC2, Lambda, Budgets, Config, SNS, CloudWatch, IAM, S3 permissions
- Python 3.12 (Lambda runtime; boto3 + pytest only needed locally to run tests)
