terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}

# ─── SNS topic & email subscription ──────────────────────────────────────────

resource "aws_sns_topic" "budget_alerts" {
  name = "finops-budget-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow AWS Budgets to publish to the SNS topic
resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowBudgetsPublish"
      Effect = "Allow"
      Principal = {
        Service = "budgets.amazonaws.com"
      }
      Action   = "SNS:Publish"
      Resource = aws_sns_topic.budget_alerts.arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

# ─── AWS Budget ($50/month) ───────────────────────────────────────────────────
#
# Every notification routes through SNS only. The SNS topic has a single
# confirmed email subscription, so each threshold delivers exactly one email.
# (Adding subscriber_email_addresses here as well would double every alert.)

locals {
  budget_thresholds = [
    { threshold = 50, type = "ACTUAL" },
    { threshold = 70, type = "ACTUAL" },
    { threshold = 80, type = "ACTUAL" },
    { threshold = 90, type = "ACTUAL" },
    { threshold = 100, type = "ACTUAL" },
    { threshold = 80, type = "FORECASTED" },
    { threshold = 100, type = "FORECASTED" },
  ]
}

resource "aws_budgets_budget" "monthly_cost" {
  name         = "finops-monthly-50-usd"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.type
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }
}

# ─── AWS Config setup ─────────────────────────────────────────────────────────

resource "aws_s3_bucket" "config_logs" {
  bucket        = "finops-config-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "finops-config-logs"
    Type = "Governance"
  }
}

resource "aws_s3_bucket_policy" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "config_recorder" {
  name = "finops-config-recorder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_recorder" {
  role       = aws_iam_role.config_recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "main" {
  name     = "finops-config-recorder"
  role_arn = aws_iam_role.config_recorder.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "finops-config-delivery"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# ─── SCP simulation — IAM deny policy for test user ─────────────────────────
#
# Mirrors the SCP in documentation/policies/scp-deny-untagged.json using an
# IAM Deny policy, which produces the same UnauthorizedOperation error without
# needing AWS Organizations.
#
# NOTE: No aws_iam_access_key is created here on purpose — that would write the
# secret access key into Terraform state in plaintext. Generate a short-lived
# key for testing out-of-band and delete it afterwards (see module outputs).

resource "aws_iam_user" "scp_test_user" {
  name = "finops-scp-test-user"

  tags = {
    Name    = "finops-scp-test-user"
    Purpose = "SCP simulation testing"
  }
}

# Allow the test user to attempt EC2 launches (so the deny is what stops them)
resource "aws_iam_user_policy_attachment" "scp_test_ec2_access" {
  user       = aws_iam_user.scp_test_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_policy" "deny_untagged_ec2" {
  name        = "finops-deny-untagged-ec2"
  description = "Simulates SCP: blocks ec2:RunInstances when CostCenter tag is absent or empty"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyRunInstancesMissingCostCenter"
        Effect   = "Deny"
        Action   = "ec2:RunInstances"
        Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = {
          Null = {
            "aws:RequestTag/CostCenter" = "true"
          }
        }
      },
      {
        Sid      = "DenyRunInstancesEmptyCostCenter"
        Effect   = "Deny"
        Action   = "ec2:RunInstances"
        Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/CostCenter" = ""
          }
        }
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "scp_test_deny" {
  user       = aws_iam_user.scp_test_user.name
  policy_arn = aws_iam_policy.deny_untagged_ec2.arn
}

# ─── Tagging policy — require CostCenter on EC2 instances ────────────────────

resource "aws_config_config_rule" "require_costcenter_tag" {
  name        = "require-costcenter-tag-ec2"
  description = "Flags any EC2 instance that is missing a CostCenter tag"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
