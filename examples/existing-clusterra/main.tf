# Existing Clusterra Cluster - Re-connect

module "clusterra" {
  source = "../../"

  region       = var.region
  cluster_name = var.cluster_name
  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id

  # Required for events module
  cluster_id = var.cluster_id
  tenant_id  = var.tenant_id
}

variable "region" { type = string }
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "cluster_id" { type = string }
variable "tenant_id" { type = string }

output "events_sqs_url" {
  value = module.clusterra.events_sqs_url
}

output "install_hooks_command" {
  value = module.clusterra.install_hooks_command
}
