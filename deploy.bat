@echo off
setlocal EnableDelayedExpansion

REM Tailscale Exit Node Multi-Cloud Deployment Script (Windows)
REM Usage: deploy.bat <action> <cloud> <region> [options]
REM
REM Examples:
REM   deploy.bat deploy aws us-east-1
REM   deploy.bat destroy gcp us-central1
REM   deploy.bat plan azure eastus
REM   deploy.bat list aws
REM   deploy.bat status

REM Configuration
set "SCRIPT_DIR=%~dp0"
set "PROVIDERS_DIR=%SCRIPT_DIR%providers"
set "SECRETS_FILE=%USERPROFILE%\.secrets\tailscale\secrets.tfvars"
set "STATE_DIR=%USERPROFILE%\.tailscale-exit-nodes\state"

REM Default regions
set "DEFAULT_REGION_aws=us-east-1"
set "DEFAULT_REGION_gcp=us-central1"
set "DEFAULT_REGION_azure=eastus"
set "DEFAULT_REGION_oci=us-ashburn-1"

REM Parse arguments
set "ACTION="
set "CLOUD="
set "REGION="
set "AUTO_APPROVE="
set "EXTRA_VARS="

:parse_args
if "%~1"=="" goto :end_parse
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="-y" (
    set "AUTO_APPROVE=-auto-approve"
    shift
    goto :parse_args
)
if /i "%~1"=="--yes" (
    set "AUTO_APPROVE=-auto-approve"
    shift
    goto :parse_args
)
if /i "%~1"=="--var" (
    set "EXTRA_VARS=!EXTRA_VARS! -var "%~2""
    shift
    shift
    goto :parse_args
)
if /i "%~1"=="deploy" (
    set "ACTION=deploy"
    shift
    goto :parse_args
)
if /i "%~1"=="destroy" (
    set "ACTION=destroy"
    shift
    goto :parse_args
)
if /i "%~1"=="plan" (
    set "ACTION=plan"
    shift
    goto :parse_args
)
if /i "%~1"=="list" (
    set "ACTION=list"
    shift
    goto :parse_args
)
if /i "%~1"=="status" (
    set "ACTION=status"
    shift
    goto :parse_args
)
if /i "%~1"=="aws" (
    set "CLOUD=aws"
    shift
    goto :parse_args
)
if /i "%~1"=="gcp" (
    set "CLOUD=gcp"
    shift
    goto :parse_args
)
if /i "%~1"=="azure" (
    set "CLOUD=azure"
    shift
    goto :parse_args
)
if /i "%~1"=="oci" (
    set "CLOUD=oci"
    shift
    goto :parse_args
)
REM Assume remaining arg is region
if "%REGION%"=="" (
    set "REGION=%~1"
)
shift
goto :parse_args

:end_parse

REM Handle actions
if "%ACTION%"=="" goto :show_help
if "%ACTION%"=="status" goto :show_status
if "%ACTION%"=="list" goto :list_regions

REM Validate inputs
if "%CLOUD%"=="" (
    echo [ERROR] Cloud provider is required.
    echo Usage: %0 %ACTION% ^<aws^|gcp^|azure^|oci^> ^<region^>
    exit /b 1
)

call :validate_cloud
if errorlevel 1 exit /b 1

REM Set default region if not specified
if "%REGION%"=="" (
    call set "REGION=%%DEFAULT_REGION_%CLOUD%%%"
    echo [INFO] Using default region: %REGION%
)

call :check_prerequisites
if errorlevel 1 exit /b 1

REM Run terraform
call :run_terraform_init
if errorlevel 1 exit /b 1

if "%ACTION%"=="deploy" (
    call :run_terraform_apply
) else if "%ACTION%"=="destroy" (
    call :run_terraform_destroy
) else if "%ACTION%"=="plan" (
    call :run_terraform_plan
)

goto :eof

REM ===== Functions =====

:show_help
echo.
echo Tailscale Exit Node Multi-Cloud Deployment
echo.
echo Usage:
echo     %0 ^<action^> ^<cloud^> ^<region^> [options]
echo.
echo Actions:
echo     deploy    Deploy a new exit node
echo     destroy   Destroy an existing exit node
echo     plan      Show what would be deployed/destroyed
echo     list      List available regions for a cloud provider
echo     status    Show all deployed exit nodes
echo.
echo Cloud Providers:
echo     aws       Amazon Web Services
echo     gcp       Google Cloud Platform
echo     azure     Microsoft Azure
echo     oci       Oracle Cloud Infrastructure
echo.
echo Options:
echo     -y, --yes           Auto-approve terraform apply/destroy
echo     -h, --help          Show this help message
echo     --var "KEY=VALUE"   Pass additional terraform variables
echo.
echo Common Variables (use with --var):
echo     use_fixed_ip=true           Allocate static/reserved public IP
echo     auto_approve_exit_node=false Disable auto-approval (manual approval needed)
echo     instance_name_prefix=NAME    Custom hostname prefix
echo.
echo     AWS:   instance_type=t3.micro
echo     GCP:   machine_type=e2-small, gcp_zone=us-central1-b
echo     Azure: vm_size=Standard_B1s, resource_group_name=my-rg
echo     OCI:   oci_config_profile=PROD, instance_shape=VM.Standard.A1.Flex
echo            os_type=oracle-linux, instance_ocpus=2, instance_memory_gb=12
echo.
echo Examples:
echo     %0 deploy aws us-east-1
echo     %0 deploy aws us-east-1 --var "use_fixed_ip=true" -y
echo     %0 deploy oci eu-frankfurt-1 --var "oci_config_profile=PROD" -y
echo     %0 destroy azure eastus -y
echo     %0 list aws
echo     %0 status
echo.
echo Setup:
echo     Create secrets file at: %SECRETS_FILE%
echo.
echo     Required variables:
echo       tailscale_api_key = "tskey-api-..."
echo       tailscale_tailnet = "your-email@example.com"
echo.
echo     For GCP, also add:
echo       gcp_project = "your-project-id"
echo.
echo     For OCI: tenancy is auto-read from ~/.oci/config (no extra config needed)
echo.
echo See README.md for full variables reference.
echo.
exit /b 0

:check_prerequisites
REM Check terraform
where terraform >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Terraform is not installed. Please install Terraform 1.5+
    exit /b 1
)

REM Check secrets file
if not exist "%SECRETS_FILE%" (
    echo [ERROR] Secrets file not found at: %SECRETS_FILE%
    echo Create it with tailscale_api_key and tailscale_tailnet variables.
    exit /b 1
)

REM Create state directory
if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"

exit /b 0

:validate_cloud
if not exist "%PROVIDERS_DIR%\%CLOUD%" (
    echo [ERROR] Invalid cloud provider or provider not found: %CLOUD%
    echo Supported: aws, gcp, azure, oci
    exit /b 1
)
exit /b 0

:list_regions
if "%CLOUD%"=="" (
    echo [ERROR] Please specify a cloud provider: deploy.bat list ^<aws^|gcp^|azure^|oci^>
    exit /b 1
)

echo.
echo Available regions for %CLOUD%:
echo.

if "%CLOUD%"=="aws" (
    echo   us-east-1         us-east-2         us-west-1
    echo   us-west-2         eu-west-1         eu-west-2
    echo   eu-west-3         eu-central-1      eu-north-1
    echo   ap-southeast-1    ap-southeast-2    ap-northeast-1
    echo   ap-northeast-2    ap-south-1        sa-east-1
    echo   ca-central-1      me-south-1        af-south-1
    echo   il-central-1
)
if "%CLOUD%"=="gcp" (
    echo   us-central1       us-east1          us-east4
    echo   us-west1          us-west2          us-west3
    echo   us-west4          europe-west1      europe-west2
    echo   europe-west3      europe-west4      europe-west6
    echo   europe-north1     asia-east1        asia-east2
    echo   asia-northeast1   asia-northeast2   asia-northeast3
    echo   asia-south1       asia-southeast1   asia-southeast2
    echo   australia-southeast1 southamerica-east1 me-west1
)
if "%CLOUD%"=="azure" (
    echo   eastus            eastus2           westus
    echo   westus2           westus3           centralus
    echo   northeurope       westeurope        uksouth
    echo   ukwest            francecentral     germanywestcentral
    echo   swedencentral     norwayeast        japaneast
    echo   japanwest         koreacentral      southeastasia
    echo   eastasia          centralindia      australiaeast
    echo   brazilsouth       canadacentral     israelcentral
)
if "%CLOUD%"=="oci" (
    echo   us-ashburn-1      us-phoenix-1      us-sanjose-1
    echo   us-chicago-1      ca-toronto-1      ca-montreal-1
    echo   eu-frankfurt-1    eu-amsterdam-1    eu-zurich-1
    echo   uk-london-1       ap-tokyo-1        ap-osaka-1
    echo   ap-seoul-1        ap-singapore-1    ap-sydney-1
    echo   ap-melbourne-1    ap-mumbai-1       sa-saopaulo-1
    echo   me-dubai-1        af-johannesburg-1 il-jerusalem-1
)

echo.
call set "DEFAULT=%%DEFAULT_REGION_%CLOUD%%%"
echo Default: %DEFAULT%
echo.
exit /b 0

:show_status
echo.
echo Deployed Tailscale Exit Nodes:
echo.

set "FOUND="
for /d %%c in ("%STATE_DIR%\*") do (
    set "CLOUD_NAME=%%~nxc"
    for %%s in ("%%c\*.tfstate") do (
        set "FOUND=1"
        set "REGION_NAME=%%~ns"
        echo   * !CLOUD_NAME! / !REGION_NAME!
    )
)

if not defined FOUND (
    echo   No exit nodes currently deployed
)
echo.
exit /b 0

:run_terraform_init
set "PROVIDER_DIR=%PROVIDERS_DIR%\%CLOUD%"
set "STATE_CLOUD_DIR=%STATE_DIR%\%CLOUD%"

if not exist "%STATE_CLOUD_DIR%" mkdir "%STATE_CLOUD_DIR%"

echo [INFO] Initializing Terraform for %CLOUD% / %REGION%...
terraform -chdir="%PROVIDER_DIR%" init -upgrade
exit /b %errorlevel%

:run_terraform_plan
set "STATE_FILE=%STATE_DIR%\%CLOUD%\%REGION%.tfstate"
echo [INFO] Planning %CLOUD% exit node in %REGION%...
terraform -chdir="%PROVIDER_DIR%" plan -lock-timeout=30s -var="region=%REGION%" -var-file="%SECRETS_FILE%" -state="%STATE_FILE%" %EXTRA_VARS%
exit /b %errorlevel%

:run_terraform_apply
set "STATE_FILE=%STATE_DIR%\%CLOUD%\%REGION%.tfstate"
echo [INFO] Deploying %CLOUD% exit node in %REGION%...
terraform -chdir="%PROVIDER_DIR%" apply %AUTO_APPROVE% -lock-timeout=30s -var="region=%REGION%" -var-file="%SECRETS_FILE%" -state="%STATE_FILE%" %EXTRA_VARS%
if errorlevel 1 exit /b 1

echo.
echo [SUCCESS] Exit node deployed and auto-approved!
echo.
echo To use this exit node:
echo.
echo   tailscale set --exit-node=ts-exit-%CLOUD%-%REGION%
echo   curl ifconfig.io
echo.
echo To disconnect:
echo.
echo   tailscale set --exit-node=""
echo.
exit /b 0

:run_terraform_destroy
set "STATE_FILE=%STATE_DIR%\%CLOUD%\%REGION%.tfstate"

if not exist "%STATE_FILE%" (
    echo [WARNING] No state file found for %CLOUD%/%REGION%. Nothing to destroy.
    exit /b 0
)

echo [INFO] Destroying %CLOUD% exit node in %REGION%...
terraform -chdir="%PROVIDER_DIR%" destroy %AUTO_APPROVE% -lock-timeout=30s -var="region=%REGION%" -var-file="%SECRETS_FILE%" -state="%STATE_FILE%" %EXTRA_VARS%
if errorlevel 1 exit /b 1

REM Clean up state files
del "%STATE_FILE%" 2>nul
del "%STATE_FILE%.backup" 2>nul

echo [SUCCESS] Exit node destroyed!
exit /b 0
