# Deployment Verification Log

Captured after `terraform apply` on the redeploy (account `412381768295`, region `eu-west-1`).

## Terraform

```
Apply complete! Resources: 33 added, 1 changed, 0 destroyed.
terraform state list  → 40 resources
terraform fmt -check -recursive  → clean
```

State is stored remotely in S3 (`finops-tfstate-412381768295`, key `finops/terraform.tfstate`) with native lockfile.

## Unit tests

```
$ pytest -q
.............                                                            [100%]
13 passed
```

Covers: zombie-tag gate, instance age, CPU averaging, EBS deletion, EIP release
(only unassociated), the three EC2 termination gates (not-tagged / too-young /
idle / active), and multi-region discovery.

## Part 1 — zombie resources live

| Resource | ID | State |
|---|---|---|
| EC2 | `i-0f7b7102562cceeb3` | running, t3.medium |
| EBS | `vol-0e108083244e9c895` | available (unattached) |
| EIP | `99.81.239.171` | no AssociationId (unassociated) |

## Part 2 — governance

- Budget `finops-monthly-50-usd`: **7** notification thresholds, all SNS-only
  (no duplicate `subscriber_email_addresses`).
- SNS topic `finops-budget-alerts`: one email subscription to
  `joel.ackah@amalitech.com` (confirm via the email link to activate).
- AWS Config rule `require-costcenter-tag-ec2`: ACTIVE.
- IAM `finops-scp-test-user`: created with `AmazonEC2FullAccess` +
  `finops-deny-untagged-ec2`. No access key in Terraform state.

## Part 3 — mixed-instances ASG

`finops-mixed-instances-asg` (min 1 / desired 3 / max 5):

```
+------------+-----------------------+------------+-------------+
|     AZ     |          ID           | Lifecycle  |    Type     |
+------------+-----------------------+------------+-------------+
| eu-west-1a | i-0cb0e63f93cc175c4   | None       | t3.medium   |   <- On-Demand base
| eu-west-1c | i-0dca30ecbfff6f2d9   | spot       | t3.medium   |   <- Spot
| eu-west-1b | i-09dc7e1aa0f18a8ff   | spot       | t3.medium   |   <- Spot
+------------+-----------------------+------------+-------------+
```

1 On-Demand + 2 Spot across three AZs — the cost-aware mix working as designed.
capacity-optimized selected the t3.medium Spot pool as the highest-capacity option.
