terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.25.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.region
}

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

# Idle EC2 instance — t3.medium with no meaningful workload
resource "aws_instance" "idle_ec2" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.medium"

  tags = {
    Name = "zombie-idle-ec2"
    Type = "ZombieAsset"
  }
}

# Unattached EBS volume — 10 GB, not attached to any instance
resource "aws_ebs_volume" "unattached" {
  availability_zone = "${var.region}a"
  size              = 10
  type              = "gp3"

  tags = {
    Name = "zombie-unattached-ebs"
    Type = "ZombieAsset"
  }
}

# Unassociated Elastic IP — allocated but not attached to anything
resource "aws_eip" "unassociated" {
  domain = "vpc"

  tags = {
    Name = "zombie-unassociated-eip"
    Type = "ZombieAsset"
  }
}
