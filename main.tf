variable "region" {
  description = "AWS region for the exit node"
  type        = string
}

provider "aws" {
  region                   = var.region
  shared_credentials_files = ["~/Google Drive/My Drive/secrets/gadyterracredential"]
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "tailscale_exit_node" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.nano"
  
  user_data = <<-EOF
    #!/bin/bash
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p
    tailscale up --authkey=${file("~/.secrets/tailscale.key")} --advertise-exit-node
  EOF
  
  tags = {
    Name = "tailscale-exit-node-${var.region}"
  }
}