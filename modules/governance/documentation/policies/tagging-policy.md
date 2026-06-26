# CostCenter Tagging Policy for EC2 Instances

## Purpose

The `CostCenter` tag is the primary mechanism for allocating AWS compute costs to business units, teams, or projects. Every EC2 instance must carry this tag so that:

- AWS Cost Explorer can break down spend per team or project.
- Monthly budget reports are attributable to the correct owner.
- The FinOps team can identify unowned ("zombie") resources and initiate cleanup.

Without consistent `CostCenter` tagging, cost reports become ambiguous and chargeback/showback models break down.

---

## Two-layer enforcement model

This project enforces the `CostCenter` tag at two independent layers. Both are necessary — neither is sufficient on its own.

### Layer 1 — Detective: AWS Config (`REQUIRED_TAGS`)

| Property | Detail |
|---|---|
| Terraform resource | `aws_config_config_rule.require_costcenter_tag` in `governance-arch/main.tf` |
| Rule identifier | `REQUIRED_TAGS` (AWS managed) |
| Scope | `AWS::EC2::Instance` |
| How it works | Continuously evaluates all EC2 instances in the account. Any instance missing the `CostCenter` tag is marked **NON_COMPLIANT** in the AWS Config dashboard. |
| Limitation | **Reactive only.** The instance is already running by the time the violation is flagged. Config cannot stop the launch. |

### Layer 2 — Preventive: Service Control Policy (`scp-deny-untagged.json`)

| Property | Detail |
|---|---|
| Policy file | `governance-arch/documentation/policies/scp-deny-untagged.json` |
| How it works | AWS Organizations SCP that is evaluated **before** IAM policies. The API call is rejected at the Organizations layer before any EC2 capacity is provisioned. |
| Limitation | Requires AWS Organizations. Does not apply to the management (root) account. |

Use both layers together: SCP stops the launch at the gate, and Config catches anything that slips through (for example, resources launched by root or before the SCP was in place).

---

## SCP policy breakdown

The policy file contains three statements.

### Statement 1 — `DenyRunInstancesMissingCostCenter`

```json
"Condition": {
  "Null": { "aws:RequestTag/CostCenter": "true" }
}
```

Blocks `ec2:RunInstances` when the `CostCenter` tag key is entirely absent from the launch request.

### Statement 2 — `DenyRunInstancesEmptyCostCenter`

```json
"Condition": {
  "StringEquals": { "aws:RequestTag/CostCenter": "" }
}
```

Blocks `ec2:RunInstances` when the `CostCenter` tag is present but its value is an empty string. This prevents teams from bypassing Statement 1 by passing `--tag-specifications 'Key=CostCenter,Value='`.

### Statement 3 — `ProtectCostCenterTagFromModificationOrRemoval`

```json
"Condition": {
  "ForAnyValue:StringEquals": { "aws:TagKeys": "CostCenter" },
  "ArnNotLike": { "aws:PrincipalARN": "arn:aws:iam::*:role/FinOpsTagAdmin" }
}
```

Denies `ec2:DeleteTags` and `ec2:CreateTags` on any resource when `CostCenter` is among the tag keys being modified, unless the caller is the `FinOpsTagAdmin` role. This prevents:

- Deleting the `CostCenter` tag from a running instance.
- Overwriting the value to an unrecognized or empty string.

> **Note:** Because this statement also covers `ec2:CreateTags`, non-admin principals cannot update the `CostCenter` tag value after launch. Only `FinOpsTagAdmin` can correct a mistyped value. Plan tag values carefully at launch time, or grant the `FinOpsTagAdmin` role to the team responsible for tag corrections.

---

## Where to attach the SCP

SCPs must be attached at the AWS Organizations level. They have no effect in a standalone account.

```
AWS Organizations root
└── Workloads OU               ← attach SCP here
    ├── Dev account
    ├── Staging account
    └── Prod account
```

**Recommended attachment point:** the OU that contains all workload accounts (dev, staging, prod). Do not attach to the management account OU — SCPs do not apply to the management account regardless.

### Steps to attach via AWS CLI

```bash
# 1. Create the SCP
aws organizations create-policy \
  --name "DenyUntaggedEC2Launches" \
  --type SERVICE_CONTROL_POLICY \
  --description "Blocks ec2:RunInstances when CostCenter tag is missing or empty" \
  --content file://governance-arch/documentation/policies/scp-deny-untagged.json

# 2. Note the PolicyId from the output (e.g. p-xxxxxxxxxx), then attach it
aws organizations attach-policy \
  --policy-id p-xxxxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx   # replace with your Workloads OU ID
```

---

## How to test the SCP

Run the following after attaching the SCP to an account. Use a non-admin IAM principal (not root, not `FinOpsTagAdmin`).

### Test 1 — Launch without any tags (should be DENIED)

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxxxxxxxxxxx \
  --instance-type t3.micro \
  --count 1 \
  --region eu-west-1
```

Expected response:

```
An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation.
Encoded authorization failure message: ...
```

### Test 2 — Launch with empty CostCenter value (should be DENIED)

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxxxxxxxxxxx \
  --instance-type t3.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=CostCenter,Value=}]' \
  --region eu-west-1
```

Expected: same `UnauthorizedOperation` error.

### Test 3 — Launch with a valid CostCenter value (should be ALLOWED)

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxxxxxxxxxxx \
  --instance-type t3.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=CostCenter,Value=engineering}]' \
  --region eu-west-1
```

Expected: instance launches successfully.

> Terminate the test instance immediately after confirming the allow case.

---

## Break-glass and exceptions

| Scenario | Guidance |
|---|---|
| Emergency launch without known cost center | Assume the `FinOpsTagAdmin` role, launch with `CostCenter=breakglass`, and update to the correct value within 24 hours. |
| Correcting a mistyped tag value | Only `FinOpsTagAdmin` can call `ec2:CreateTags` or `ec2:DeleteTags` on the `CostCenter` key. Raise a request to the FinOps team. |
| Excluding a specific automated role | Add its ARN to the `ArnNotLike` condition in Statement 3 of `scp-deny-untagged.json` and re-attach the policy. |
| Management account resources | SCPs do not apply to the management account. Enforce tagging there through IAM permission boundaries or AWS Config alone. |
