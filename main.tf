terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES
# ─────────────────────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "deploy_new_cluster" {
  description = "Set to true to generate ParallelCluster configuration and deployment scripts"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "Name of the ParallelCluster (existing or new)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}

# New Cluster Settings (Optional)
variable "head_node_instance_type" {
  description = "Head node instance type (for new clusters)"
  type        = string
  default     = "t3.small"
}

variable "compute_instance_type" {
  description = "Compute node instance type (for new clusters)"
  type        = string
  default     = "c5.large"
}

variable "ssh_key_name" {
  description = "SSH key name (for new clusters)"
  type        = string
  default     = "clusterra-headnode-key"
}

variable "min_count" {
  description = "Min compute nodes"
  type        = number
  default     = 0
}

variable "max_count" {
  description = "Max compute nodes"
  type        = number
  default     = 10
}

# Connectivity Settings
variable "slurm_jwt_secret_name" {
  type    = string
  default = "clusterra-slurm-jwt-key"
}

variable "slurm_api_port" {
  type    = number
  default = 6830
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULES
# ─────────────────────────────────────────────────────────────────────────────

module "parallelcluster" {
  count = var.deploy_new_cluster ? 1 : 0

  source = "./modules/parallelcluster"

  cluster_name           = var.cluster_name
  region                 = var.region
  vpc_id                 = var.vpc_id
  subnet_id              = var.subnet_id
  ssh_key_name           = var.ssh_key_name
  head_node_instance_type = var.head_node_instance_type
  compute_instance_type   = var.compute_instance_type
  min_count              = var.min_count
  max_count              = var.max_count
  slurm_jwt_secret_name  = var.slurm_jwt_secret_name
}

module "connectivity" {
  # If creating a new cluster, user must run pcluster create separately first.
  # So we always deploy this, but it will fail if cluster doesn't exist yet.
  source = "./modules/connectivity"

  region               = var.region
  cluster_name         = var.cluster_name
  vpc_id               = var.vpc_id
  subnet_id            = var.subnet_id
  slurm_jwt_secret_name = var.slurm_jwt_secret_name
  slurm_api_port        = var.slurm_api_port
  
  # Does not auto-wire IP from module.parallelcluster because it doesn't run create.
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "pcluster_config_path" {
  value = var.deploy_new_cluster ? module.parallelcluster[0].cluster_config_path : null
}

output "deploy_command" {
  value = var.deploy_new_cluster ? module.parallelcluster[0].deploy_command : null
}

output "clusterra_onboarding" {
  value = module.connectivity.clusterra_onboarding
}
