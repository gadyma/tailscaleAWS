# Basic (ephemeral IP, Ubuntu, Always Free micro)
terraform apply -var="region=eu-frankfurt-1"

# With fixed IP
terraform apply -var="region=eu-frankfurt-1" -var="use_reserved_ip=true"

# ARM Flex shape (if capacity available)
terraform apply -var="region=eu-frankfurt-1" -var="instance_shape=VM.Standard.A1.Flex"