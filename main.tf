variable "region" {
  description = "AWS region for the exit node"
  type        = string
}

variable "tailscale_api_key_parameter" {
  description = "AWS SSM Parameter name for Tailscale API key"
  type        = string
  default     = "/tailscale/api_key"
}

variable "tailscale_tailnet_parameter" {
  description = "AWS SSM Parameter name for Tailscale tailnet"
  type        = string
  default     = "/tailscale/tailnet"
}

variable "aws_profile" {
  description = "AWS profile to use"
  type        = string
  default     = "default"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    tailscale = {
      source = "tailscale/tailscale"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# Separate provider for parameter store in il-central-1
provider "aws" {
  alias   = "il_central"
  region  = "il-central-1"
  profile = var.aws_profile
}

data "aws_ssm_parameter" "tailscale_api_key" {
  provider = aws.il_central
  name     = var.tailscale_api_key_parameter
}

data "aws_ssm_parameter" "tailscale_tailnet" {
  provider = aws.il_central
  name     = var.tailscale_tailnet_parameter
}

provider "tailscale" {
  api_key = data.aws_ssm_parameter.tailscale_api_key.value
  tailnet = data.aws_ssm_parameter.tailscale_tailnet.value
}


data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "tailscale_tailnet_key" "exit_node" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  tags          = ["tag:exit-node"]
}

resource "aws_instance" "tailscale_exit_node" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  #tags = merge(var.custom_tags, { Name = "exit-${var.region}" })


  user_data = <<-EOF
    #!/bin/bash
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p
    tailscale up --authkey=${tailscale_tailnet_key.exit_node.key} --advertise-exit-node --hostname=myexitpoint-${var.region}
  EOF
  
  tags = {
    Name = "tailscale-exit-node-${var.region}"
  }
}