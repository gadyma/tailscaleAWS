# GCP Tailscale Exit Node
# Usage: terraform apply -var="region=us-central1" -var="gcp_project=my-project" -var-file="~/.secrets/tailscale/secrets.tfvars"

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
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
  description = "GCP region for the exit node"
  type        = string
}

variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_zone" {
  description = "GCP zone (defaults to region-a)"
  type        = string
  default     = ""
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

variable "machine_type" {
  description = "GCP machine type"
  type        = string
  default     = "e2-micro"
}

variable "instance_name_prefix" {
  description = "Prefix for the exit node hostname"
  type        = string
  default     = "ts-exit"
}

variable "use_fixed_ip" {
  description = "Whether to create and use a static external IP"
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

locals {
  zone               = var.gcp_zone != "" ? var.gcp_zone : "${var.region}-a"
  tailscale_hostname = "${var.instance_name_prefix}-gcp-${var.region}"
}

# Providers
provider "google" {
  project = var.gcp_project
  region  = var.region
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Data Sources
data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

# Tailscale Auth Key
resource "tailscale_tailnet_key" "exit_node" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  tags          = length(var.tailscale_tags) > 0 ? var.tailscale_tags : null
}

# Firewall - Allow egress only (Tailscale uses outbound connections)
resource "google_compute_firewall" "tailscale_egress" {
  name    = "${var.instance_name_prefix}-${var.region}-egress"
  network = "default"

  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["tailscale-exit"]
}

# Static External IP (optional)
resource "google_compute_address" "tailscale" {
  count        = var.use_fixed_ip ? 1 : 0
  name         = "${var.instance_name_prefix}-${var.region}-ip"
  region       = var.region
  address_type = "EXTERNAL"
}

# Compute Instance
resource "google_compute_instance" "tailscale_exit_node" {
  name         = "${var.instance_name_prefix}-gcp-${var.region}"
  machine_type = var.machine_type
  zone         = local.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 10
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Use static IP if configured, otherwise ephemeral
      nat_ip = var.use_fixed_ip ? google_compute_address.tailscale[0].address : null
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -e
    
    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p
    
    # Start Tailscale as exit node
    tailscale up --authkey=${tailscale_tailnet_key.exit_node.key} --advertise-exit-node --hostname=${local.tailscale_hostname}
  EOF

  tags = ["tailscale-exit"]

  labels = {
    project = "tailscale-exit-node"
    cloud   = "gcp"
    region  = replace(var.region, "-", "_")
  }

  scheduling {
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Wait for device to register with Tailscale
resource "time_sleep" "wait_for_tailscale" {
  count           = var.auto_approve_exit_node ? 1 : 0
  depends_on      = [google_compute_instance.tailscale_exit_node]
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
output "instance_name" {
  description = "GCP instance name"
  value       = google_compute_instance.tailscale_exit_node.name
}

output "public_ip" {
  description = "Public IP address"
  value       = var.use_fixed_ip ? google_compute_address.tailscale[0].address : google_compute_instance.tailscale_exit_node.network_interface[0].access_config[0].nat_ip
}

output "fixed_ip" {
  description = "Whether using fixed (static) IP"
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

output "zone" {
  description = "GCP zone where instance is deployed"
  value       = local.zone
}
