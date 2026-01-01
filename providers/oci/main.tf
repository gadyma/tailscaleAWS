# Oracle Cloud (OCI) Tailscale Exit Node
# Usage: terraform apply -var="region=us-ashburn-1" -var-file="~/.secrets/tailscale/secrets.tfvars"
# Note: OCI has a generous free tier with Always Free eligible shapes
# Uses ~/.oci/config automatically (same as OCI CLI)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# Variables
variable "region" {
  description = "OCI region for the exit node"
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

variable "oci_config_profile" {
  description = "OCI config profile name (from ~/.oci/config) - tenancy is read from this profile automatically"
  type        = string
  default     = "DEFAULT"
}

variable "oci_tenancy_ocid" {
  description = "OCI tenancy OCID (optional - automatically read from ~/.oci/config profile if not specified)"
  type        = string
  default     = ""
}

variable "compartment_ocid" {
  description = "OCI compartment OCID (optional - defaults to tenancy root from config)"
  type        = string
  default     = ""
}

variable "instance_shape" {
  description = "OCI instance shape (VM.Standard.E2.1.Micro is Always Free)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_ocpus" {
  description = "Number of OCPUs (only for Flex shapes)"
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "Memory in GB (only for Flex shapes)"
  type        = number
  default     = 6
}

variable "instance_name_prefix" {
  description = "Prefix for the exit node hostname"
  type        = string
  default     = "ts-exit"
}

variable "use_fixed_ip" {
  description = "Whether to create and use a reserved (fixed) public IP"
  type        = bool
  default     = false
}

variable "auto_approve_exit_node" {
  description = "Automatically approve the exit node routes in Tailscale"
  type        = bool
  default     = true
}

variable "os_type" {
  description = "Operating system type: 'oracle-linux' or 'ubuntu'"
  type        = string
  default     = "ubuntu"
  validation {
    condition     = contains(["oracle-linux", "ubuntu"], var.os_type)
    error_message = "os_type must be 'oracle-linux' or 'ubuntu'"
  }
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags to apply to the exit node (e.g., ['tag:exit-node']). Required if using autoApprovers in ACL."
  type        = list(string)
  default     = ["tag:exit-node"]
}

# Read tenancy OCID from ~/.oci/config if not provided
# This uses pure Terraform and works on Windows, Linux, and Mac
locals {
  # Try to read the OCI config file
  oci_config_path = pathexpand("~/.oci/config")
  oci_config_exists = fileexists(local.oci_config_path)
  oci_config_content = local.oci_config_exists ? file(local.oci_config_path) : ""
  
  # Parse the config file to extract tenancy for the specified profile
  # Split into lines and find the profile section
  config_lines = local.oci_config_exists ? split("\n", local.oci_config_content) : []
  
  # Find tenancy value from config (simplified parsing)
  # This looks for "tenancy=" after the profile header
  tenancy_from_config = local.oci_config_exists ? try(regex(
    "(?s)\\[${var.oci_config_profile}\\][^\\[]*tenancy\\s*=\\s*([^\\s\\r\\n]+)",
    local.oci_config_content
  )[0], "") : ""
  
  # Use provided value or fall back to config file
  tenancy_ocid   = var.oci_tenancy_ocid != "" ? var.oci_tenancy_ocid : local.tenancy_from_config
  compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : local.tenancy_ocid
  is_flex_shape  = length(regexall("Flex", var.instance_shape)) > 0
  tailscale_hostname = "${var.instance_name_prefix}-oci-${var.region}"
  
  # Cloud-init for Ubuntu
  cloud_config_ubuntu = <<-EOF
#cloud-config
package_update: true
packages:
  - iptables-persistent

runcmd:
  # Enable IP forwarding
  - echo 'net.ipv4.ip_forward = 1' | tee /etc/sysctl.d/99-tailscale.conf
  - echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
  - sysctl -p /etc/sysctl.d/99-tailscale.conf
  
  # Configure NAT/masquerade for exit node traffic
  - iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
  - netfilter-persistent save
  
  # Optimize UDP GRO forwarding for better performance
  - ethtool -K ens3 rx-udp-gro-forwarding on || true
  
  # Install and configure Tailscale
  - curl -fsSL https://tailscale.com/install.sh | sh
  - systemctl enable tailscaled
  - systemctl start tailscaled
  - sleep 5
  - tailscale up --authkey=${tailscale_tailnet_key.exit_node.key} --advertise-exit-node --hostname=${local.tailscale_hostname}
EOF

  # Cloud-init for Oracle Linux
  cloud_config_oracle_linux = <<-EOF
#cloud-config
runcmd:
  # Disable firewalld (OCI security lists handle this)
  - systemctl stop firewalld || true
  - systemctl disable firewalld || true
  
  # Clear any existing iptables rules
  - iptables -F
  - iptables -t nat -F
  - iptables -P INPUT ACCEPT
  - iptables -P FORWARD ACCEPT
  - iptables -P OUTPUT ACCEPT
  
  # Enable IP forwarding
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  - echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
  - sysctl -p
  
  # Configure NAT/masquerade for exit node traffic
  - iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
  
  # Save iptables rules
  - dnf install -y iptables-services
  - systemctl enable iptables
  - service iptables save
  
  # Optimize UDP GRO forwarding for better performance
  - ethtool -K ens3 rx-udp-gro-forwarding on || true
  
  # Install and configure Tailscale
  - curl -fsSL https://tailscale.com/install.sh | sh
  - systemctl enable tailscaled
  - systemctl start tailscaled
  - sleep 5
  - tailscale up --authkey=${tailscale_tailnet_key.exit_node.key} --advertise-exit-node --hostname=${local.tailscale_hostname}
EOF

  cloud_config = var.os_type == "ubuntu" ? local.cloud_config_ubuntu : local.cloud_config_oracle_linux
}

# Providers - uses ~/.oci/config for auth (no key/fingerprint prompts)
provider "oci" {
  config_file_profile = var.oci_config_profile
  region              = var.region
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Data Sources
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Ubuntu images for x86/AMD shapes
data "oci_core_images" "ubuntu_amd" {
  count                    = var.os_type == "ubuntu" && !local.is_flex_shape ? 1 : 0
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Ubuntu images for ARM/Flex shapes
data "oci_core_images" "ubuntu_arm" {
  count                    = var.os_type == "ubuntu" && local.is_flex_shape ? 1 : 0
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Oracle Linux images
data "oci_core_images" "oracle_linux" {
  count                    = var.os_type == "oracle-linux" ? 1 : 0
  compartment_id           = local.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  image_id = var.os_type == "ubuntu" ? (
    local.is_flex_shape ? data.oci_core_images.ubuntu_arm[0].images[0].id : data.oci_core_images.ubuntu_amd[0].images[0].id
  ) : data.oci_core_images.oracle_linux[0].images[0].id
}

# VCN
resource "oci_core_vcn" "tailscale" {
  compartment_id = local.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "${var.instance_name_prefix}-vcn-${var.region}"
  dns_label      = "tsexit"
}

# Internet Gateway
resource "oci_core_internet_gateway" "tailscale" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.tailscale.id
  display_name   = "${var.instance_name_prefix}-igw"
  enabled        = true
}

# Route Table
resource "oci_core_route_table" "tailscale" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.tailscale.id
  display_name   = "${var.instance_name_prefix}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.tailscale.id
  }
}

# Security List
resource "oci_core_security_list" "tailscale" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.tailscale.id
  display_name   = "${var.instance_name_prefix}-sl"

  # Allow all egress (required for exit node)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  # SSH for debugging
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Tailscale UDP (41641) - helps with direct connections
  ingress_security_rules {
    protocol = "17" # UDP
    source   = "0.0.0.0/0"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # ICMP for diagnostics
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
  }
}

# Subnet
resource "oci_core_subnet" "tailscale" {
  compartment_id    = local.compartment_id
  vcn_id            = oci_core_vcn.tailscale.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "${var.instance_name_prefix}-subnet"
  dns_label         = "tssubnet"
  route_table_id    = oci_core_route_table.tailscale.id
  security_list_ids = [oci_core_security_list.tailscale.id]
}

# Reserved Public IP (optional)
resource "oci_core_public_ip" "tailscale" {
  count          = var.use_fixed_ip ? 1 : 0
  compartment_id = local.compartment_id
  display_name   = "${var.instance_name_prefix}-ip-${var.region}"
  lifetime       = "RESERVED"
}

# Tailscale Auth Key
resource "tailscale_tailnet_key" "exit_node" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  tags          = length(var.tailscale_tags) > 0 ? var.tailscale_tags : null
}

# SSH Key for instance access
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Compute Instance
resource "oci_core_instance" "tailscale" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_id
  shape               = var.instance_shape
  display_name        = "${var.instance_name_prefix}-oci-${var.region}"

  dynamic "shape_config" {
    for_each = local.is_flex_shape ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.tailscale.id
    assign_public_ip = var.use_fixed_ip ? false : true
    display_name     = "${var.instance_name_prefix}-vnic"
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.ssh.public_key_openssh
    user_data           = base64encode(local.cloud_config)
  }

  freeform_tags = {
    "Project" = "tailscale-exit-node"
    "Cloud"   = "oci"
    "Region"  = var.region
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Get VNIC attachment for reserved IP assignment
data "oci_core_vnic_attachments" "tailscale" {
  count          = var.use_fixed_ip ? 1 : 0
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.tailscale.id
}

data "oci_core_vnic" "tailscale" {
  count   = var.use_fixed_ip ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.tailscale[0].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "tailscale" {
  count   = var.use_fixed_ip ? 1 : 0
  vnic_id = data.oci_core_vnic.tailscale[0].id
}

# Assign reserved IP to instance
resource "oci_core_public_ip" "tailscale_assigned" {
  count          = var.use_fixed_ip ? 1 : 0
  compartment_id = local.compartment_id
  display_name   = "${var.instance_name_prefix}-ip-${var.region}"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.tailscale[0].private_ips[0].id
}

# Wait for device to register with Tailscale
resource "time_sleep" "wait_for_tailscale" {
  count           = var.auto_approve_exit_node ? 1 : 0
  depends_on      = [oci_core_instance.tailscale]
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
  description = "OCI instance OCID"
  value       = oci_core_instance.tailscale.id
}

output "public_ip" {
  description = "Public IP address"
  value       = var.use_fixed_ip ? oci_core_public_ip.tailscale_assigned[0].ip_address : oci_core_instance.tailscale.public_ip
}

output "fixed_ip" {
  description = "Whether using fixed (reserved) IP"
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

output "ssh_command" {
  description = "SSH command to connect to instance"
  value       = "ssh -i <private_key_file> ${var.os_type == "ubuntu" ? "ubuntu" : "opc"}@${var.use_fixed_ip ? oci_core_public_ip.tailscale_assigned[0].ip_address : oci_core_instance.tailscale.public_ip}"
}

output "availability_domain" {
  description = "OCI availability domain"
  value       = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

output "ssh_private_key" {
  description = "SSH private key for debugging (sensitive)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
