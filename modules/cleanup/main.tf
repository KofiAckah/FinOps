terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# ─── Lambda package ──────────────────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/garbage_collector.py"
  output_path = "${path.module}/lambda/garbage_collector.zip"
}

# ─── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "garbage_collector" {
  name = "zombie-garbage-collector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "garbage_collector" {
  name        = "zombie-garbage-collector-policy"
  description = "Allow Lambda to detect and delete zombie EC2 resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read-only discovery + deletion of resources that are unattached by
      # definition (available volumes, unassociated EIPs). The "unattached"
      # state is itself the safety signal — these carry no live workload.
      {
        Sid    = "DiscoverAndReleaseDetachedResources"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DeleteVolume",
          "ec2:DescribeAddresses",
          "ec2:ReleaseAddress",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
        ]
        Resource = "*"
      },
      # Terminating a *running* instance is the highest blast-radius action,
      # so it is fenced to instances explicitly tagged as disposable. Even if
      # the function logic regressed, IAM cannot terminate a production
      # instance that is not tagged Type=ZombieAsset.
      {
        Sid      = "TerminateZombieInstancesOnly"
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Type" = "ZombieAsset"
          }
        }
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "garbage_collector" {
  role       = aws_iam_role.garbage_collector.name
  policy_arn = aws_iam_policy.garbage_collector.arn
}

# ─── Lambda function ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "garbage_collector" {
  name              = "/aws/lambda/${aws_lambda_function.garbage_collector.function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "garbage_collector" {
  function_name    = "zombie-garbage-collector"
  description      = "Deletes unattached EBS volumes, unassociated EIPs, and idle zombie EC2 instances across all regions"
  role             = aws_iam_role.garbage_collector.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "garbage_collector.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300

  environment {
    variables = {
      CPU_IDLE_THRESHOLD = var.cpu_idle_threshold
      IDLE_LOOKBACK_DAYS = var.idle_lookback_days
      ZOMBIE_TAG_KEY     = var.zombie_tag_key
      ZOMBIE_TAG_VALUE   = var.zombie_tag_value
    }
  }

  tags = {
    Name = "zombie-garbage-collector"
    Type = "FinOpsAutomation"
  }
}

# ─── EventBridge — every Sunday at 23:59 UTC ─────────────────────────────────

resource "aws_cloudwatch_event_rule" "weekly_cleanup" {
  name                = "zombie-weekly-cleanup"
  description         = "Triggers zombie garbage collector every Sunday at 23:59 UTC"
  schedule_expression = "cron(59 23 ? * SUN *)"
}

resource "aws_cloudwatch_event_target" "garbage_collector" {
  rule      = aws_cloudwatch_event_rule.weekly_cleanup.name
  target_id = "ZombieGarbageCollector"
  arn       = aws_lambda_function.garbage_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.garbage_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_cleanup.arn
}
