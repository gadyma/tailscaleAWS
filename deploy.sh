#!/bin/bash
#
# Tailscale Exit Node Multi-Cloud Deployment Script
# Usage: ./deploy.sh <action> <cloud> <region> [options]
#
# Examples:
#   ./deploy.sh deploy aws us-east-1
#   ./deploy.sh destroy gcp us-central1
#   ./deploy.sh plan azure eastus
#   ./deploy.sh list aws
#   ./deploy.sh status
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="${SCRIPT_DIR}/providers"
SECRETS_FILE="${HOME}/.secrets/tailscale/secrets.tfvars"
STATE_DIR="${HOME}/.tailscale-exit-nodes/state"

# Cloud-specific default regions
declare -A DEFAULT_REGIONS=(
    ["aws"]="us-east-1"
    ["gcp"]="us-central1"
    ["azure"]="eastus"
    ["oci"]="us-ashburn-1"
)

# Region lists for validation
declare -A CLOUD_REGIONS=(
    ["aws"]="us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-northeast-2 ap-south-1 sa-east-1 ca-central-1 me-south-1 af-south-1 il-central-1"
    ["gcp"]="us-central1 us-east1 us-east4 us-west1 us-west2 us-west3 us-west4 europe-west1 europe-west2 europe-west3 europe-west4 europe-west6 europe-north1 asia-east1 asia-east2 asia-northeast1 asia-northeast2 asia-northeast3 asia-south1 asia-southeast1 asia-southeast2 australia-southeast1 southamerica-east1 me-west1"
    ["azure"]="eastus eastus2 westus westus2 westus3 centralus northcentralus southcentralus westcentralus canadacentral canadaeast brazilsouth northeurope westeurope uksouth ukwest francecentral francesouth germanywestcentral norwayeast switzerlandnorth switzerlandwest swedencentral polandcentral italynorth uaenorth southafricanorth australiaeast australiasoutheast australiacentral japaneast japanwest koreacentral koreasouth southeastasia eastasia centralindia westindia southindia israelcentral qatarcentral"
    ["oci"]="us-ashburn-1 us-phoenix-1 us-sanjose-1 us-chicago-1 ca-toronto-1 ca-montreal-1 sa-saopaulo-1 sa-vinhedo-1 eu-frankfurt-1 eu-amsterdam-1 eu-zurich-1 eu-madrid-1 eu-marseille-1 eu-milan-1 eu-paris-1 eu-stockholm-1 uk-london-1 uk-cardiff-1 me-dubai-1 me-jeddah-1 me-abudhabi-1 af-johannesburg-1 ap-tokyo-1 ap-osaka-1 ap-seoul-1 ap-chuncheon-1 ap-singapore-1 ap-sydney-1 ap-melbourne-1 ap-hyderabad-1 ap-mumbai-1 il-jerusalem-1"
)

# Print usage
usage() {
    cat << EOF
${BLUE}Tailscale Exit Node Multi-Cloud Deployment${NC}

${YELLOW}Usage:${NC}
    $0 <action> <cloud> <region> [options]

${YELLOW}Actions:${NC}
    deploy    Deploy a new exit node
    destroy   Destroy an existing exit node
    plan      Show what would be deployed/destroyed
    list      List available regions for a cloud provider
    status    Show all deployed exit nodes

${YELLOW}Cloud Providers:${NC}
    aws       Amazon Web Services
    gcp       Google Cloud Platform
    azure     Microsoft Azure
    oci       Oracle Cloud Infrastructure

${YELLOW}Options:${NC}
    -y, --yes           Auto-approve terraform apply/destroy
    -v, --verbose       Verbose output
    -h, --help          Show this help message
    --var KEY=VALUE     Pass additional terraform variables

${YELLOW}Common Variables (use with --var):${NC}
    use_fixed_ip=true             Allocate static/reserved public IP
    auto_approve_exit_node=false  Disable auto-approval (manual approval needed)
    instance_name_prefix=NAME     Custom hostname prefix

    AWS:   instance_type=t3.micro
    GCP:   machine_type=e2-small, gcp_zone=us-central1-b
    Azure: vm_size=Standard_B1s, resource_group_name=my-rg
    OCI:   oci_config_profile=PROD, instance_shape=VM.Standard.A1.Flex
           os_type=oracle-linux, instance_ocpus=2, instance_memory_gb=12

${YELLOW}Examples:${NC}
    $0 deploy aws us-east-1
    $0 deploy aws us-east-1 --var use_fixed_ip=true -y
    $0 deploy oci eu-frankfurt-1 --var oci_config_profile=PROD -y
    $0 destroy azure eastus -y
    $0 list aws
    $0 status

${YELLOW}Setup:${NC}
    Create secrets file at: ${SECRETS_FILE}
    
    Required variables:
      tailscale_api_key = "tskey-api-..."
      tailscale_tailnet = "your-email@example.com"
    
    For GCP, also add:
      gcp_project = "your-project-id"
    
    For OCI: tenancy is auto-read from ~/.oci/config (no extra config needed)

    See README.md for full variables reference.

EOF
    exit 0
}

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    # Check terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed. Please install Terraform 1.5+"
    fi

    # Check secrets file
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found at: $SECRETS_FILE\nCreate it with tailscale_api_key and tailscale_tailnet variables."
    fi

    # Create state directory if needed
    mkdir -p "$STATE_DIR"
}

# Validate cloud provider
validate_cloud() {
    local cloud="$1"
    if [[ ! " aws gcp azure oci " =~ " $cloud " ]]; then
        log_error "Invalid cloud provider: $cloud\nSupported: aws, gcp, azure, oci"
    fi
    
    if [[ ! -d "${PROVIDERS_DIR}/${cloud}" ]]; then
        log_error "Provider directory not found: ${PROVIDERS_DIR}/${cloud}"
    fi
}

# Validate region
validate_region() {
    local cloud="$1"
    local region="$2"
    
    if [[ -z "$region" ]]; then
        region="${DEFAULT_REGIONS[$cloud]}"
        log_info "Using default region: $region"
    fi
    
    local valid_regions="${CLOUD_REGIONS[$cloud]}"
    if [[ ! " $valid_regions " =~ " $region " ]]; then
        log_warning "Region '$region' not in known list for $cloud. Proceeding anyway..."
    fi
    
    echo "$region"
}

# List regions for a cloud provider
list_regions() {
    local cloud="$1"
    validate_cloud "$cloud"
    
    echo -e "${BLUE}Available regions for ${cloud^^}:${NC}"
    echo ""
    
    local regions="${CLOUD_REGIONS[$cloud]}"
    local count=0
    for region in $regions; do
        printf "  %-25s" "$region"
        ((count++))
        if (( count % 3 == 0 )); then
            echo ""
        fi
    done
    echo ""
    echo ""
    echo -e "${YELLOW}Default: ${DEFAULT_REGIONS[$cloud]}${NC}"
}

# Show status of all deployed nodes
show_status() {
    echo -e "${BLUE}Deployed Tailscale Exit Nodes:${NC}"
    echo ""
    
    local found=false
    for cloud_dir in "$STATE_DIR"/*/; do
        if [[ -d "$cloud_dir" ]]; then
            local cloud=$(basename "$cloud_dir")
            for state_file in "$cloud_dir"/*.tfstate; do
                if [[ -f "$state_file" ]]; then
                    found=true
                    local region=$(basename "$state_file" .tfstate)
                    local ip=$(terraform -chdir="${PROVIDERS_DIR}/${cloud}" output -state="$state_file" -raw public_ip 2>/dev/null || echo "unknown")
                    local hostname=$(terraform -chdir="${PROVIDERS_DIR}/${cloud}" output -state="$state_file" -raw tailscale_hostname 2>/dev/null || echo "unknown")
                    echo -e "  ${GREEN}●${NC} ${cloud^^} / ${region}"
                    echo -e "    Hostname: ${hostname}"
                    echo -e "    Public IP: ${ip}"
                    echo ""
                fi
            done
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        echo -e "  ${YELLOW}No exit nodes currently deployed${NC}"
    fi
}

# Run terraform command
run_terraform() {
    local action="$1"
    local cloud="$2"
    local region="$3"
    local auto_approve="$4"
    shift 4
    local extra_vars=("$@")
    
    local provider_dir="${PROVIDERS_DIR}/${cloud}"
    local state_file="${STATE_DIR}/${cloud}/${region}.tfstate"
    
    # Create state directory
    mkdir -p "${STATE_DIR}/${cloud}"
    
    # Build terraform command
    local tf_args=(
        "-chdir=${provider_dir}"
    )
    
    case "$action" in
        init)
            log_info "Initializing Terraform for ${cloud^^} / ${region}..."
            terraform "${tf_args[@]}" init -upgrade
            ;;
        plan)
            log_info "Planning ${cloud^^} exit node in ${region}..."
            terraform "${tf_args[@]}" plan \
                -lock-timeout=30s \
                -var="region=${region}" \
                -var-file="${SECRETS_FILE}" \
                -state="${state_file}" \
                "${extra_vars[@]}"
            ;;
        apply)
            log_info "Deploying ${cloud^^} exit node in ${region}..."
            local approve_flag=""
            [[ "$auto_approve" == "true" ]] && approve_flag="-auto-approve"
            
            terraform "${tf_args[@]}" apply \
                $approve_flag \
                -lock-timeout=30s \
                -var="region=${region}" \
                -var-file="${SECRETS_FILE}" \
                -state="${state_file}" \
                "${extra_vars[@]}"
            
            echo ""
            log_success "Exit node deployed and auto-approved!"
            echo ""
            echo -e "${GREEN}To use this exit node:${NC}"
            echo ""
            echo "  tailscale set --exit-node=ts-exit-${cloud}-${region}"
            echo "  curl ifconfig.io"
            echo ""
            echo -e "${GREEN}To disconnect:${NC}"
            echo ""
            echo "  tailscale set --exit-node=\"\""
            echo ""
            ;;
        destroy)
            log_info "Destroying ${cloud^^} exit node in ${region}..."
            
            if [[ ! -f "$state_file" ]]; then
                log_warning "No state file found for ${cloud}/${region}. Nothing to destroy."
                return
            fi
            
            local approve_flag=""
            [[ "$auto_approve" == "true" ]] && approve_flag="-auto-approve"
            
            terraform "${tf_args[@]}" destroy \
                $approve_flag \
                -lock-timeout=30s \
                -var="region=${region}" \
                -var-file="${SECRETS_FILE}" \
                -state="${state_file}" \
                "${extra_vars[@]}"
            
            # Clean up state file
            rm -f "${state_file}" "${state_file}.backup"
            
            log_success "Exit node destroyed!"
            ;;
    esac
}

# Main function
main() {
    local action=""
    local cloud=""
    local region=""
    local auto_approve="false"
    local verbose="false"
    local extra_vars=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -y|--yes)
                auto_approve="true"
                shift
                ;;
            -v|--verbose)
                verbose="true"
                set -x
                shift
                ;;
            --var)
                extra_vars+=("-var" "$2")
                shift 2
                ;;
            deploy|destroy|plan|list|status)
                action="$1"
                shift
                ;;
            aws|gcp|azure|oci)
                cloud="$1"
                shift
                ;;
            *)
                if [[ -z "$region" && -n "$cloud" ]]; then
                    region="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Handle special actions
    case "$action" in
        "")
            usage
            ;;
        status)
            check_prerequisites
            show_status
            exit 0
            ;;
        list)
            if [[ -z "$cloud" ]]; then
                log_error "Please specify a cloud provider: ./deploy.sh list <aws|gcp|azure|oci>"
            fi
            list_regions "$cloud"
            exit 0
            ;;
    esac
    
    # Validate inputs for deploy/destroy/plan
    if [[ -z "$cloud" ]]; then
        log_error "Cloud provider is required.\nUsage: $0 $action <aws|gcp|azure|oci> <region>"
    fi
    
    validate_cloud "$cloud"
    region=$(validate_region "$cloud" "$region")
    check_prerequisites
    
    # Run terraform
    run_terraform init "$cloud" "$region" "$auto_approve" "${extra_vars[@]}"
    
    case "$action" in
        deploy)
            run_terraform apply "$cloud" "$region" "$auto_approve" "${extra_vars[@]}"
            ;;
        destroy)
            run_terraform destroy "$cloud" "$region" "$auto_approve" "${extra_vars[@]}"
            ;;
        plan)
            run_terraform plan "$cloud" "$region" "$auto_approve" "${extra_vars[@]}"
            ;;
    esac
}

# Run main
main "$@"
