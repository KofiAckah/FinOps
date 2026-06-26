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

## Part 2 — tagging deny-policy tests (live, via `finops-scp-test-user`)

| Test | Tags on RunInstances | Result |
|---|---|---|
| 1 | none | **DENIED** — `UnauthorizedOperation … explicit deny in identity-based policy: finops-deny-untagged-ec2` |
| 2 | `CostCenter=""` (empty) | **DENIED** — same explicit deny |
| 3 | `CostCenter=FinOps` | **ALLOWED** — launched `i-0e11852cf356756e1` (terminated after) |

Temporary access key was created out-of-band for the test and deleted immediately after.

## Part 1 — garbage collector, live invocation

`aws lambda invoke --function-name zombie-garbage-collector` produced (eu-west-1 excerpt):

```json
"eu-west-1": {
  "deleted_ebs_volumes": [{"volume_id": "vol-0e108083244e9c895", "size_gb": 10}],
  "released_eips":       [{"public_ip": "99.81.239.171", "allocation_id": "eipalloc-02402f439b351106c"}],
  "ec2_instances": {
    "terminated": [],
    "skipped": [
      {"instance_id": "i-0f7b7102562cceeb3", "reason": "too_young", "age_days": 0},
      {"instance_id": "i-0cb0e63f93cc175c4", "reason": "not_zombie_tagged"}
    ]
  }
}
```

Both safety gates fired: the young zombie EC2 was spared (`too_young`) and an
ASG production instance was spared (`not_zombie_tagged`). Only the genuinely
detached EBS volume and EIP were reclaimed.

**Multi-region note:** the sweep iterated all 17 enabled regions. An org SCP
(`p-339lo1q0`) denies EC2 outside a handful of regions; those are recorded as
`{"skipped": "no_access_scp_or_disabled"}` and the sweep continues — graceful
degradation rather than a hard failure.
