# Tailscale Exit Node - Multi-Cloud Terraform

Personal, disposable VPN exit nodes across **AWS, GCP, Azure, and Oracle Cloud** using Terraform + Tailscale. Perfect for geo-testing, QA debugging, or privacy on public WiFi.

## Features

- **Auto-approve exit nodes** - No manual approval needed in Tailscale Admin Console
- **Fixed/Static IP support** - Keep the same public IP across instance restarts
- **Multi-cloud support** - AWS, GCP, Azure, and Oracle Cloud
- **Infrastructure-as-Code** with Terraform
- **Zero-config WireGuard** via Tailscale

## Why This Exists

Sometimes you need to browse the internet "as if" you're in another country:
- Testing geo-blocked content or pricing (QA/Dev)
- Debugging user-reported issues from specific regions
- Secure egress on untrusted networks (coffee shops, hotels)

Commercial VPNs are black boxes. This gives you **full control**:
- Infrastructure-as-Code with Terraform
- Tailscale's zero-config WireGuard
- **Multi-cloud support** - pick the cheapest/fastest option per region
- One-click deploy/destroy per region
- ~90% cheaper than paid VPNs

## Cost Comparison

| Cloud | Instance Type | Hourly Cost | Monthly (24/7) | Free Tier |
|-------|--------------|-------------|----------------|-----------|
| AWS | t3.nano | $0.004 | ~$3 | No |
| GCP | e2-micro | $0.008 | ~$6 | Yes (1 instance) |
| Azure | Standard_B1ls | $0.005 | ~$4 | No |
| OCI | VM.Standard.E2.1.Micro | $0.00 | **Free** | Yes (Always Free) |

**Pro tip**: OCI's Always Free tier gives you 2 free VMs forever!

## Prerequisites

1. **Terraform** 1.5+ installed
2. **Tailscale Account** - [Sign up free](https://tailscale.com/)
3. **Cloud provider CLI** configured for your target cloud(s):
   - AWS: `aws configure`
   - GCP: `gcloud auth application-default login`
   - Azure: `az login`
   - OCI: `oci setup config`

## Quick Start

### 1. Setup Secrets (One-Time)

```bash
# Create secrets directory
mkdir -p ~/.secrets/tailscale

# Copy and edit the template
cp secrets.tfvars.example ~/.secrets/tailscale/secrets.tfvars

# Edit with your values
nano ~/.secrets/tailscale/secrets.tfvars
```

**Minimum required** in `secrets.tfvars`:
```hcl
tailscale_api_key = "tskey-api-..."
tailscale_tailnet = "your-email@example.com"
```

### 2. Deploy an Exit Node

**Linux/macOS:**
```bash
chmod +x deploy.sh
./deploy.sh deploy aws us-east-1
```

**Windows:**
```cmd
deploy.bat deploy aws us-east-1
```

### 3. Connect and Use

With **auto_approve_exit_node=true** (default), the exit node is automatically approved and ready to use immediately!

**Connect** from any device:
```bash
tailscale set --exit-node=ts-exit-aws-us-east-1
curl ipinfo.io/country  # Should show US
```

**Disconnect** when done:
```bash
tailscale set --exit-node=""
```

> **Note**: If auto-approve is disabled, you'll need to manually approve the exit node in [Tailscale Admin Console](https://login.tailscale.com/admin/machines).

### 4. Destroy (Important!)

```bash
./deploy.sh destroy aws us-east-1
```

## New Variables

### Auto-Approve Exit Node

By default, exit node routes are automatically approved via the Tailscale API. To disable:

```bash
./deploy.sh deploy aws us-east-1 --var auto_approve_exit_node=false
```

### Fixed/Static IP

Keep the same public IP address even after instance restarts (useful for whitelisting):

```bash
# AWS - Elastic IP
./deploy.sh deploy aws us-east-1 --var use_fixed_ip=true

# GCP - Static External IP
./deploy.sh deploy gcp us-central1 --var use_fixed_ip=true

# Azure - Always uses static IP by default
./deploy.sh deploy azure eastus

# OCI - Reserved IP
./deploy.sh deploy oci us-ashburn-1 --var use_fixed_ip=true
```

| Cloud | Fixed IP Feature | Default |
|-------|------------------|---------|
| AWS | Elastic IP | `false` |
| GCP | Static External IP | `false` |
| Azure | Static IP (always on) | `true` |
| OCI | Reserved Public IP | `false` |

## Script Usage

```
./deploy.sh <action> <cloud> <region> [options]

Actions:
    deploy    Deploy a new exit node
    destroy   Destroy an existing exit node
    plan      Show what would be deployed/destroyed
    list      List available regions for a cloud provider
    status    Show all deployed exit nodes

Cloud Providers:
    aws       Amazon Web Services
    gcp       Google Cloud Platform
    azure     Microsoft Azure
    oci       Oracle Cloud Infrastructure

Options:
    -y, --yes           Auto-approve terraform apply/destroy
    --var KEY=VALUE     Pass additional terraform variables
```

### Examples

```bash
# Deploy with auto-approve and fixed IP
./deploy.sh deploy aws us-east-1 --var use_fixed_ip=true -y

# Deploy without auto-approving exit node (manual approval needed)
./deploy.sh deploy gcp europe-west1 --var auto_approve_exit_node=false

# Deploy to OCI with fixed IP (free!)
./deploy.sh deploy oci ap-tokyo-1 --var use_fixed_ip=true -y

# Check what's running
./deploy.sh status

# List available regions
./deploy.sh list azure

# Destroy everything
./deploy.sh destroy aws us-east-1 -y
./deploy.sh destroy gcp europe-west1 -y
```

## Cloud-Specific Setup

### AWS
No additional setup beyond `aws configure`. Uses default VPC.

### GCP
Add to `secrets.tfvars`:
```hcl
gcp_project = "your-project-id"
```

Make sure these APIs are enabled:
```bash
gcloud services enable compute.googleapis.com
```

### Azure
Works with `az login`. Creates a new resource group per region.

### Oracle Cloud (OCI)
Just run `oci setup config` - tenancy is automatically read from `~/.oci/config`. No extra configuration needed!

Default instance is **Always Free** eligible!

## Variables Reference

All variables can be passed via `--var "name=value"` or set in `secrets.tfvars`.

### Common Variables (All Providers)

| Variable | Description | Default |
|----------|-------------|---------|
| `region` | Cloud region (required, or passed as argument) | - |
| `tailscale_api_key` | Tailscale API key (required) | - |
| `tailscale_tailnet` | Tailscale tailnet name (required) | - |
| `instance_name_prefix` | Hostname prefix for exit nodes | `ts-exit` |
| `use_fixed_ip` | Allocate static/reserved public IP | `false` |
| `auto_approve_exit_node` | Auto-approve exit node in Tailscale | `true` |
| `tailscale_tags` | ACL tags (e.g., `["tag:exit-node"]`) | `["tag:exit-node"]` |

### AWS Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `instance_type` | EC2 instance type | `t3.nano` |

### GCP Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `gcp_project` | GCP project ID (required for GCP) | - |
| `gcp_zone` | GCP zone | `{region}-a` |
| `machine_type` | GCP machine type | `e2-micro` |

### Azure Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `vm_size` | Azure VM size | `Standard_B1ls` |
| `resource_group_name` | Resource group name | `tailscale-exit-nodes` |

### OCI Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `oci_config_profile` | OCI config profile in ~/.oci/config | `DEFAULT` |
| `oci_tenancy_ocid` | Tenancy OCID (auto-read from config) | - |
| `compartment_ocid` | Compartment OCID | tenancy root |
| `instance_shape` | OCI instance shape | `VM.Standard.E2.1.Micro` |
| `instance_ocpus` | OCPUs (Flex shapes only) | `1` |
| `instance_memory_gb` | Memory in GB (Flex shapes only) | `6` |
| `os_type` | OS type: `ubuntu` or `oracle-linux` | `ubuntu` |

### Example Usage

```bash
# AWS with larger instance and fixed IP
./deploy.sh deploy aws us-east-1 --var "instance_type=t3.micro" --var "use_fixed_ip=true"

# GCP with specific zone
./deploy.sh deploy gcp us-central1 --var "gcp_zone=us-central1-b"

# Azure with custom resource group
./deploy.sh deploy azure eastus --var "resource_group_name=my-vpn-nodes"

# OCI with different profile and Flex shape
./deploy.sh deploy oci us-ashburn-1 --var "oci_config_profile=PROD" --var "instance_shape=VM.Standard.A1.Flex"

# OCI with Oracle Linux instead of Ubuntu
./deploy.sh deploy oci eu-frankfurt-1 --var "os_type=oracle-linux"

# Custom hostname prefix (for multiple nodes)
./deploy.sh deploy aws us-east-1 --var "instance_name_prefix=team-dev"
./deploy.sh deploy aws us-east-1 --var "instance_name_prefix=team-prod"

# Disable auto-approve (require manual approval in Tailscale console)
./deploy.sh deploy aws us-west-2 --var "auto_approve_exit_node=false"

# With Tailscale ACL tags (required if using autoApprovers in your ACL)
./deploy.sh deploy oci eu-frankfurt-1 --var 'tailscale_tags=["tag:exit-node"]'
```

## Popular Regions

| Use Case | AWS | GCP | Azure | OCI |
|----------|-----|-----|-------|-----|
| USA East | us-east-1 | us-east1 | eastus | us-ashburn-1 |
| USA West | us-west-2 | us-west1 | westus2 | us-phoenix-1 |
| Europe | eu-west-1 | europe-west1 | westeurope | eu-frankfurt-1 |
| Asia Pacific | ap-southeast-1 | asia-southeast1 | southeastasia | ap-singapore-1 |
| Japan | ap-northeast-1 | asia-northeast1 | japaneast | ap-tokyo-1 |
| Israel | il-central-1 | me-west1 | israelcentral | il-jerusalem-1 |
| Brazil | sa-east-1 | southamerica-east1 | brazilsouth | sa-saopaulo-1 |

## Directory Structure

```
tailscale-multicloud/
├── deploy.sh              # Linux/macOS deployment script
├── deploy.bat             # Windows deployment script
├── secrets.tfvars.example # Template for secrets
├── variables.tf           # Common variables
├── providers/
│   ├── aws/
│   │   └── main.tf       # AWS configuration
│   ├── gcp/
│   │   └── main.tf       # GCP configuration
│   ├── azure/
│   │   └── main.tf       # Azure configuration
│   └── oci/
│       └── main.tf       # OCI configuration
└── README.md
```

## State Management

Terraform state is stored locally at:
- Linux/macOS: `~/.tailscale-exit-nodes/state/<cloud>/<region>.tfstate`
- Windows: `%USERPROFILE%\.tailscale-exit-nodes\state\<cloud>\<region>.tfstate`

For team use, consider migrating to remote state (S3, GCS, Azure Blob, etc.).

## Security Notes

- ✅ Tailscale auth keys are ephemeral (single-use)
- ✅ No inbound ports open (WireGuard uses outbound connections)
- ✅ Secrets stored outside the repo (`~/.secrets/`)
- ✅ Minimal instance sizes = minimal attack surface
- ⚠️ Always destroy nodes when not in use
- ⚠️ Review Tailscale ACLs for exit node permissions

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Terraform init fails | Check cloud CLI is configured: `aws sts get-caller-identity` |
| Exit node not appearing | Wait 60 seconds, check instance logs in cloud console |
| Can't connect to exit node | Approve it in Tailscale Admin Console |
| Permission denied (GCP) | Enable Compute API: `gcloud services enable compute.googleapis.com` |
| OCI shape not found | Change region or use different shape in secrets.tfvars |

## Advanced Usage

### Custom Instance Size
```bash
./deploy.sh deploy aws us-east-1 --var instance_type=t3.micro
```

### Multiple Nodes Same Region
```bash
./deploy.sh deploy aws us-east-1 --var instance_name_prefix=team-a
./deploy.sh deploy aws us-east-1 --var instance_name_prefix=team-b
```

### Verbose Mode
```bash
./deploy.sh deploy aws us-east-1 -v
```

## Legal Disclaimer

This is for **legitimate testing, development, and privacy use cases only**. Respect:
- Website Terms of Service
- Local laws
- Copyright / licensing rules

The author provides this "as is" for educational purposes.

---

**⭐ Star if useful! Contributions welcome.**  
**Built with ❤️ for DevOps folks who hate vendor lock-in.**
