\# Tailscale Exit Node Terraform Module



Personal, disposable VPN exit nodes in any AWS region using Terraform + Tailscale. Costs ~$0.004/hr (t3.nano). Perfect for geo-testing, QA debugging, or privacy on public WiFi.



\## Why This Exists



Sometimes you need to browse the internet "as if" you're in another country:

\- Testing geo-blocked content or pricing (QA/Dev)

\- Debugging user-reported issues from specific regions

\- Secure egress on untrusted networks (coffee shops, hotels)



Commercial VPNs are black boxes. This gives you \*\*full control\*\*:

\- Infra-as-Code with Terraform

\- Tailscale's zero-config WireGuard

\- One-click deploy/destroy per region

\- ~90% cheaper than paid VPNs



\## Prerequisites



1\. \*\*AWS Account\*\* with permissions for:

&nbsp;  - EC2 (t3.nano, default VPC)

&nbsp;  - SSM Parameter Store (il-central-1)

&nbsp;  - IAM (read SSM)



2\. \*\*Tailscale Account\*\* - generate API key:

&nbsp;  ```

&nbsp;  # Admin Console → Settings → Keys → Generate auth key

&nbsp;  # Copy the "tskey-auth-..." value

&nbsp;  ```



3\. \*\*Terraform\*\* 1.5+ \& AWS CLI configured



\## Setup (One-Time)



Store credentials securely in AWS SSM (il-central-1):



```bash

\# Tailscale API Key (SecureString)

aws ssm put-parameter \\

&nbsp; --name "/tailscale/api\_key" \\

&nbsp; --value "tskey-auth-abc123def456..." \\

&nbsp; --type "SecureString" \\

&nbsp; --description "Tailscale API key" \\

&nbsp; --region il-central-1



\# Tailnet name (String - your login email)

aws ssm put-parameter \\

&nbsp; --name "/tailscale/tailnet" \\

&nbsp; --value "your-email@example.com" \\

&nbsp; --type "String" \\

&nbsp; --description "Tailscale tailnet" \\

&nbsp; --region il-central-1

```



\*\*Verify\*\*:

```bash

aws ssm get-parameter --name "/tailscale/api\_key" --region il-central-1 --with-decryption

aws ssm get-parameters-by-path --path "/tailscale" --region il-central-1

```



\## Usage



\### Deploy Exit Node

```bash

\# Plan first (recommended)

terraform plan -var="region=us-east-1"



\# Deploy

terraform apply -var="region=us-east-1"



\# Output: instance IP, Tailscale key, hostname

```



\### Sample Regions (Low-cost, good coverage)

```

\- us-east-1     (N. Virginia, USA East)

\- us-west-2     (Oregon, USA West)

\- eu-west-1     (Ireland, Europe)

\- ap-southeast-1 (Singapore, Asia)

\- sa-east-1     (São Paulo, Brazil)

\- il-central-1  (Tel Aviv, Israel)\*

```



\\\* \*il-central-1 is cheap but may have different peering\*



\### Connect from Any Device

1\. \*\*Approve exit node\*\* in Tailscale Admin Console:

&nbsp;  - Machines → Find `myexitpoint-us-east-1`

&nbsp;  - Toggle "Use as exit node"



2\. \*\*Connect\*\* (CLI/GUI):

&nbsp;  ```bash

&nbsp;  # CLI

&nbsp;  tailscale set --exit-node=myexitpoint-us-east-1

&nbsp;  

&nbsp;  # GUI: Select exit node from dropdown

&nbsp;  

&nbsp;  # Verify

&nbsp;  curl ipinfo.io/country  # Should show target country

&nbsp;  ```



\### Destroy (Always!)

```bash

terraform destroy -var="region=us-east-1"

```



\## Full Workflow Example



```bash

\# 1. Setup (one-time)

aws ssm put-parameter --name "/tailscale/api\_key" --value "tskey-auth-..." --type SecureString --region il-central-1

aws ssm put-parameter --name "/tailscale/tailnet" --value "user@example.com" --type String --region il-central-1



\# 2. US testing

terraform apply -var="region=us-east-1"

tailscale set --exit-node=myexitpoint-us-east-1

curl ipinfo.io  # USA IP

tailscale set --exit-node=""  # Disconnect



\# 3. EU testing  

terraform apply -var="region=eu-west-1"

tailscale set --exit-node=myexitpoint-eu-west-1

curl ipinfo.io  # EU IP



\# 4. Cleanup

terraform destroy -var="region=eu-west-1"

terraform destroy -var="region=us-east-1"

```



\## Cost Breakdown

```

t3.nano: $0.004/hr → $0.10/day → $3/month (if always on)

EBS 8GB: $0.10/GB-month → $0.80/month

Total: ~$4/month for 24/7 across 1 region

```



\*\*Pro tip\*\*: Use AWS Cost Explorer + destroy unused nodes!



\## Security Notes



\- ✅ API keys in SSM SecureString (encrypted)

\- ✅ Ephemeral Tailscale keys (single-use)

\- ✅ No open ports (Tailscale WireGuard only)

\- ✅ t3.nano = minimal attack surface

\- ⚠️ Destroy when not needed

\- ⚠️ Review Tailscale ACLs for exit node usage



\## Customization



Edit `variables.tf`:

```hcl

variable "instance\_type" { default = "t3.nano" }  # t4g.nano (ARM) even cheaper

variable "custom\_tags" { type = map(string) }

```



Add to `aws\_instance`:

```hcl

instance\_type = var.instance\_type

tags = merge(var.custom\_tags, { Name = "exit-${var.region}" })

```



\## Troubleshooting



| Issue | Fix |

|-------|-----|

| "Permission denied" SSM | `aws iam policy attach-user --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess` |

| Tailscale key expires | Re-run `terraform apply` (creates new ephemeral key) |

| Exit node not listed | Approve in Admin Console → Machines → Toggle "exit node" |

| `terraform plan` errors | Check SSM params exist: `aws ssm get-parameters-by-path --path /tailscale --region il-central-1` |



\## Legal Disclaimer



This is for \*\*legitimate testing, development, and privacy use cases only\*\*. Respect:

\- Website Terms of Service

\- Local laws

\- Copyright / licensing rules



The author provides this "as is" for educational purposes.



---



\*\*⭐ Star if useful! Contributions welcome (tests, regions, ARM support).\*\*  

\*\*Built with ❤️ for DevOps folks who hate vendor lock-in.\*\*

