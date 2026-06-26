terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

# ─── Data sources ─────────────────────────────────────────────────────────────

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ─── Security group ───────────────────────────────────────────────────────────

resource "aws_security_group" "app" {
  name        = "finops-asg-sg"
  description = "Allow HTTP inbound for stateless app instances"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "finops-asg-sg"
    CostCenter = "engineering"
  }
}

# ─── Launch Template ──────────────────────────────────────────────────────────

resource "aws_launch_template" "app" {
  name_prefix   = "finops-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.medium"

  vpc_security_group_ids = [aws_security_group.app.id]

  # Simple stateless web server — starts immediately on boot
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    systemctl enable --now httpd
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-type)
    LIFECYCLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-life-cycle)
    echo "<h1>FinOps Demo App</h1>
    <p>Instance ID: $INSTANCE_ID</p>
    <p>Instance Type: $INSTANCE_TYPE</p>
    <p>Lifecycle: $LIFECYCLE</p>" > /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "finops-asg-instance"
      CostCenter = "engineering"
      ManagedBy  = "asg"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name       = "finops-asg-volume"
      CostCenter = "engineering"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Auto Scaling Group — Mixed Instances Policy ──────────────────────────────
#
# on_demand_base_capacity = 1          → 1 On-Demand instance always running
# on_demand_percentage_above_base = 0  → all scale-out capacity uses Spot
# Instance overrides: t3.medium + t3.large (two Spot types for diversity)
# spot_allocation_strategy = capacity-optimized → picks the pool with most
#   available capacity, reducing interruption rate

resource "aws_autoscaling_group" "mixed" {
  name                = "finops-mixed-instances-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = data.aws_subnets.default.ids

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      # On-Demand base instance type
      override {
        instance_type = "t3.medium"
      }

      # Spot instance type 1
      override {
        instance_type = "t3.large"
      }

      # Spot instance type 2 — fallback pool for higher availability
      override {
        instance_type = "t3a.large"
      }
    }
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120
  wait_for_capacity_timeout = "0"

  tag {
    key                 = "Name"
    value               = "finops-mixed-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "CostCenter"
    value               = "engineering"
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }
}

# ─── Scale-out policy (add instances under load) ──────────────────────────────

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "finops-scale-out"
  autoscaling_group_name = aws_autoscaling_group.mixed.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 120
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "finops-asg-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale out when avg CPU > 70% for 2 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mixed.name
  }
}

# ─── Scale-in policy (remove instances when idle) ─────────────────────────────

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "finops-scale-in"
  autoscaling_group_name = aws_autoscaling_group.mixed.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "finops-asg-low-cpu"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "Scale in when avg CPU < 20% for 3 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mixed.name
  }
}
