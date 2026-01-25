# New Cluster with Clusterra

module "clusterra" {
  source = "../../"

  # Required
  region       = var.region
  cluster_name = var.cluster_name
  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id

  # New cluster settings
  deploy_new_cluster      = true
  head_node_instance_type = "t3.medium"
  compute_instance_type   = "c5.xlarge"
  ssh_key_name            = var.ssh_key_name
  min_count               = 0
  max_count               = 10

  # Clusterra settings (add after registration)
  cluster_id = var.cluster_id
  tenant_id  = var.tenant_id
}

# Variables
variable "region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ssh_key_name" {
  type = string
}

variable "cluster_id" {
  type    = string
  default = ""
}

variable "tenant_id" {
  type    = string
  default = ""
}

# Outputs
output "pcluster_config_path" {
  value = module.clusterra.pcluster_config_path
}

output "clusterra_onboarding" {
  value = module.clusterra.clusterra_onboarding
}

output "events_sqs_url" {
  value = module.clusterra.events_sqs_url
}

output "install_hooks_command" {
  value = module.clusterra.install_hooks_command
}
