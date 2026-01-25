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

# Clusterra Settings
variable "cluster_id" {
  description = "Clusterra cluster ID (clus_xxx) - provided after registration"
  type        = string
  default     = ""
}

variable "tenant_id" {
  description = "Clusterra tenant ID (ten_xxx)"
  type        = string
  default     = ""
}

variable "clusterra_api_url" {
  description = "Clusterra API URL"
  type        = string
  default     = "https://api.clusterra.cloud"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULES
# ─────────────────────────────────────────────────────────────────────────────

module "parallelcluster" {
  count = var.deploy_new_cluster ? 1 : 0

  source = "./modules/parallelcluster"

  cluster_name            = var.cluster_name
  region                  = var.region
  vpc_id                  = var.vpc_id
  subnet_id               = var.subnet_id
  ssh_key_name            = var.ssh_key_name
  head_node_instance_type = var.head_node_instance_type
  compute_instance_type   = var.compute_instance_type
  min_count               = var.min_count
  max_count               = var.max_count
  slurm_jwt_secret_name   = var.slurm_jwt_secret_name
}

module "connectivity" {
  source = "./modules/connect"

  region                = var.region
  cluster_name          = var.cluster_name
  vpc_id                = var.vpc_id
  subnet_id             = var.subnet_id
  slurm_jwt_secret_name = var.slurm_jwt_secret_name
  slurm_api_port        = var.slurm_api_port
}

module "events" {
  # Only deploy if cluster_id and tenant_id are set
  count = var.cluster_id != "" && var.tenant_id != "" ? 1 : 0

  source = "./modules/events"

  cluster_name      = var.cluster_name
  cluster_id        = var.cluster_id
  tenant_id         = var.tenant_id
  region            = var.region
  clusterra_api_url = var.clusterra_api_url
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
  description = "Values to provide to Clusterra for cluster registration"
  value       = module.connectivity.clusterra_onboarding
}

output "events_sqs_url" {
  description = "SQS queue URL for Slurm hooks (set after cluster_id/tenant_id are configured)"
  value       = var.cluster_id != "" && var.tenant_id != "" ? module.events[0].sqs_queue_url : null
}

output "install_hooks_command" {
  description = "Run this on head node to install event hooks"
  value       = var.cluster_id != "" && var.tenant_id != "" ? module.events[0].install_hooks_command : null
}
