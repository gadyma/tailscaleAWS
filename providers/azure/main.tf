# Azure Tailscale Exit Node
# Usage: terraform apply -var="region=eastus" -var-file="~/.secrets/tailscale/secrets.tfvars"

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# Variables
variable "region" {
  description = "Azure region for the exit node"
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

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_B1ls"
}

variable "instance_name_prefix" {
  description = "Prefix for the exit node hostname"
  type        = string
  default     = "ts-exit"
}

variable "resource_group_name" {
  description = "Resource group name (created if not exists)"
  type        = string
  default     = "tailscale-exit-nodes"
}

variable "use_fixed_ip" {
  description = "Whether to use a static public IP (Azure always uses static by default, this is for consistency)"
  type        = bool
  default     = true
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

# Locals
locals {
  tailscale_hostname = "${var.instance_name_prefix}-azure-${var.region}"
}

# Providers
provider "azurerm" {
  features {}
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Random suffix for unique resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Resource Group
resource "azurerm_resource_group" "tailscale" {
  name     = "${var.resource_group_name}-${var.region}"
  location = var.region

  tags = {
    Project = "tailscale-exit-node"
    Cloud   = "azure"
  }
}

# Virtual Network
resource "azurerm_virtual_network" "tailscale" {
  name                = "${var.instance_name_prefix}-vnet-${random_string.suffix.result}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.tailscale.location
  resource_group_name = azurerm_resource_group.tailscale.name
}

# Subnet
resource "azurerm_subnet" "tailscale" {
  name                 = "${var.instance_name_prefix}-subnet"
  resource_group_name  = azurerm_resource_group.tailscale.name
  virtual_network_name = azurerm_virtual_network.tailscale.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Public IP
resource "azurerm_public_ip" "tailscale" {
  name                = "${var.instance_name_prefix}-pip-${random_string.suffix.result}"
  location            = azurerm_resource_group.tailscale.location
  resource_group_name = azurerm_resource_group.tailscale.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Project = "tailscale-exit-node"
  }
}

# Network Security Group - Minimal (Tailscale uses outbound only)
resource "azurerm_network_security_group" "tailscale" {
  name                = "${var.instance_name_prefix}-nsg-${random_string.suffix.result}"
  location            = azurerm_resource_group.tailscale.location
  resource_group_name = azurerm_resource_group.tailscale.name

  # Allow all outbound (required for Tailscale)
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Deny all inbound by default (Tailscale doesn't need it)
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Project = "tailscale-exit-node"
  }
}

# Network Interface
resource "azurerm_network_interface" "tailscale" {
  name                = "${var.instance_name_prefix}-nic-${random_string.suffix.result}"
  location            = azurerm_resource_group.tailscale.location
  resource_group_name = azurerm_resource_group.tailscale.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.tailscale.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tailscale.id
  }
}

# NSG Association
resource "azurerm_network_interface_security_group_association" "tailscale" {
  network_interface_id      = azurerm_network_interface.tailscale.id
  network_security_group_id = azurerm_network_security_group.tailscale.id
}

# Tailscale Auth Key
resource "tailscale_tailnet_key" "exit_node" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  tags          = length(var.tailscale_tags) > 0 ? var.tailscale_tags : null
}

# Virtual Machine
resource "azurerm_linux_virtual_machine" "tailscale" {
  name                = "${var.instance_name_prefix}-azure-${var.region}"
  resource_group_name = azurerm_resource_group.tailscale.name
  location            = azurerm_resource_group.tailscale.location
  size                = var.vm_size
  admin_username      = "azureuser"
  
  network_interface_ids = [
    azurerm_network_interface.tailscale.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
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
  )

  tags = {
    Project = "tailscale-exit-node"
    Cloud   = "azure"
    Region  = var.region
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Generate SSH key for VM access (optional, for debugging)
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Wait for device to register with Tailscale
resource "time_sleep" "wait_for_tailscale" {
  count           = var.auto_approve_exit_node ? 1 : 0
  depends_on      = [azurerm_linux_virtual_machine.tailscale]
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
output "vm_id" {
  description = "Azure VM ID"
  value       = azurerm_linux_virtual_machine.tailscale.id
}

output "public_ip" {
  description = "Public IP address"
  value       = azurerm_public_ip.tailscale.ip_address
}

output "fixed_ip" {
  description = "Whether using fixed (static) IP - Azure always uses static"
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

output "resource_group" {
  description = "Resource group name"
  value       = azurerm_resource_group.tailscale.name
}

output "ssh_private_key" {
  description = "SSH private key for debugging (sensitive)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
