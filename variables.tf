# Common variables for all cloud providers

variable "region" {
  description = "Cloud region for the exit node"
  type        = string
}

variable "tailscale_api_key" {
  description = "Tailscale API key"
  type        = string
  sensitive   = true
}

variable "tailscale_tailnet" {
  description = "Tailscale tailnet (your email or org name)"
  type        = string
}

variable "instance_name_prefix" {
  description = "Prefix for the exit node hostname"
  type        = string
  default     = "ts-exit"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Project   = "tailscale-exit-node"
    ManagedBy = "terraform"
  }
}
