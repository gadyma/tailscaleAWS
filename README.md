terraform apply -var="region=us-east-1"
terraform destroy -var="region=us-east-1"

terraform destroy  \
  -var="region=eu-west-1" \
  -var="tailscale_api_key=$(cat ~/.secrets/tailscale_api_key)" \
  -var="tailnet=gadymargalit@gmail.com"


https://tailscale.com/kb/1282/docker 5:30 - Emperal....

https://claude.ai/chat/1ca3b33d-218f-4373-aac2-afc1099e2a7f
