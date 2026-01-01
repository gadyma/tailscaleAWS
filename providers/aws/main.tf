# AWS Tailscale Exit Node
# Usage: terraform apply -var="region=us-east-1" -var-file="~/.secrets/tailscale/secrets.tfvars"

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.13"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# Variables
variable "region" {
  description = "AWS region for the exit node"
  type        = string
}

variable "tailscale_api_key" {
  description = "Tailscale API key"
  type        = string
  sensitive   = true
}

variable "tailscale_tailnet" {
  description = "Tailscale tailnet"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.nano"
}

variable "instance_name_prefix" {
  description = "Prefix for the exit node hostname"
  type        = string
  default     = "ts-exit"
}

variable "use_fixed_ip" {
  description = "Whether to create and use an Elastic IP (fixed public IP)"
  type        = bool
  default     = false
}

variable "auto_approve_exit_node" {
  description = "Automatically approve the exit node routes in Tailscale"
  type        = bool
  default     = true
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags to apply to the exit node (e.g., ['tag:exit-node']). Required if using autoApprovers in ACL."
  type        = list(string)
  default     = ["tag:exit-node"]
}

# Providers
provider "aws" {
  region = var.region
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Data Sources
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

data "aws_vpc" "default" {
  default = true
}

# Tailscale Auth Key
resource "tailscale_tailnet_key" "exit_node" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  tags          = length(var.tailscale_tags) > 0 ? var.tailscale_tags : null
}

# Security Group - Allow only Tailscale (no open ports needed with WireGuard)
resource "aws_security_group" "tailscale_exit" {
  name        = "${var.instance_name_prefix}-${var.region}-sg"
  description = "Security group for Tailscale exit node"
  vpc_id      = data.aws_vpc.default.id

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.instance_name_prefix}-${var.region}-sg"
    Project = "tailscale-exit-node"
    Cloud   = "aws"
  }
}

# EC2 Instance
resource "aws_instance" "tailscale_exit_node" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.tailscale_exit.id]

  user_data = <<-EOF
    #!/bin/bash
    set -e
    
    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p
    
    # Start Tailscale as exit node
    tailscale up --authkey=${tailscale_tailnet_key.exit_node.key} --advertise-exit-node --hostname=${var.instance_name_prefix}-aws-${var.region}
  EOF

  tags = {
    Name    = "${var.instance_name_prefix}-aws-${var.region}"
    Project = "tailscale-exit-node"
    Cloud   = "aws"
    Region  = var.region
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Elastic IP (optional - for fixed public IP)
resource "aws_eip" "tailscale" {
  count    = var.use_fixed_ip ? 1 : 0
  instance = aws_instance.tailscale_exit_node.id
  domain   = "vpc"

  tags = {
    Name    = "${var.instance_name_prefix}-aws-${var.region}-eip"
    Project = "tailscale-exit-node"
    Cloud   = "aws"
  }
}

# Local for hostname
locals {
  tailscale_hostname = "${var.instance_name_prefix}-aws-${var.region}"
}

# Wait for device to register with Tailscale
resource "time_sleep" "wait_for_tailscale" {
  count           = var.auto_approve_exit_node ? 1 : 0
  depends_on      = [aws_instance.tailscale_exit_node]
  create_duration = "90s"
}

# Look up the device in Tailscale
data "tailscale_device" "exit_node" {
  count    = var.auto_approve_exit_node ? 1 : 0
  hostname = local.tailscale_hostname
  wait_for = "120s"

  depends_on = [time_sleep.wait_for_tailscale]
}

# Approve exit node routes
resource "tailscale_device_subnet_routes" "exit_node" {
  count     = var.auto_approve_exit_node ? 1 : 0
  device_id = data.tailscale_device.exit_node[0].node_id
  routes    = ["0.0.0.0/0", "::/0"]
}

# Outputs
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.tailscale_exit_node.id
}

output "public_ip" {
  description = "Public IP address"
  value       = var.use_fixed_ip ? aws_eip.tailscale[0].public_ip : aws_instance.tailscale_exit_node.public_ip
}

output "fixed_ip" {
  description = "Whether using fixed (Elastic) IP"
  value       = var.use_fixed_ip
}

output "tailscale_hostname" {
  description = "Tailscale hostname for this exit node"
  value       = local.tailscale_hostname
}

output "tailscale_device_id" {
  description = "Tailscale device ID (if auto-approved)"
  value       = var.auto_approve_exit_node ? data.tailscale_device.exit_node[0].node_id : null
}

output "exit_node_approved" {
  description = "Whether exit node routes were auto-approved"
  value       = var.auto_approve_exit_node
}

output "exit_node_command" {
  description = "Command to use this exit node"
  value       = "tailscale set --exit-node=${local.tailscale_hostname}"
}
