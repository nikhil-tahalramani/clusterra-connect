# Existing Non-Clusterra Cluster - Full Setup

module "clusterra" {
  source = "../../"

  region       = var.region
  cluster_name = var.cluster_name
  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id

  # Existing slurmrestd JWT secret
  slurm_jwt_secret_name = var.slurm_jwt_secret_name
  slurm_api_port        = var.slurm_api_port

  # Clusterra settings (add after registration)
  cluster_id = var.cluster_id
  tenant_id  = var.tenant_id
}

variable "region" { type = string }
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "slurm_jwt_secret_name" { type = string }
variable "slurm_api_port" { 
  type    = number 
  default = 6820 
}
variable "cluster_id" { 
  type    = string 
  default = "" 
}
variable "tenant_id" { 
  type    = string 
  default = "" 
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
