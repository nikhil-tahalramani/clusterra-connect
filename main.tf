terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Store state and lock files in generated/ folder
  backend "local" {
    path = "generated/terraform.tfstate"
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

variable "secondary_subnet_id" {
  description = "Secondary Subnet ID (different AZ)"
  type        = string
}

# New Cluster Settings (Optional)
variable "head_node_instance_type" {
  description = "Head node instance type (for new clusters)"
  type        = string
  default     = "t3.medium"
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

variable "head_node_instance_id" {
  description = "EC2 instance ID of head node (populated after pcluster create)"
  type        = string
  default     = ""
}

variable "clusterra_service_network_id" {
  description = "Clusterra's VPC Lattice Service Network ID (from Control Plane)"
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULES
# ─────────────────────────────────────────────────────────────────────────────

module "parallelcluster" {
  count = var.deploy_new_cluster ? 1 : 0

  source = "./modules/cluster-create"

  cluster_name            = var.cluster_name
  region                  = var.region
  vpc_id                  = var.vpc_id
  subnet_id               = var.subnet_id
  ssh_key_name            = var.ssh_key_name
  head_node_instance_type = var.head_node_instance_type
  compute_instance_type   = var.compute_instance_type
  min_count               = var.min_count
  max_count               = var.max_count
  secondary_subnet_id     = var.secondary_subnet_id

  # Clusterra Integration
  cluster_id           = var.cluster_id
  tenant_id            = var.tenant_id
  clusterra_account_id = var.clusterra_account_id
  clusterra_region     = var.clusterra_region
}


# ─────────────────────────────────────────────────────────────────────────────
# Add clusterra_account_id variable
# ─────────────────────────────────────────────────────────────────────────────
variable "clusterra_account_id" {
  description = "Clusterra's AWS account ID for cross-account access"
  type        = string
  default     = "493245399820" # Default to Prod if not specified
}

variable "clusterra_region" {
  description = "Clusterra AWS Region"
  type        = string
  default     = "ap-south-1"
}

module "connectivity" {
  source = "./modules/cluster-connect"

  region                       = var.region
  cluster_name                 = var.cluster_name
  cluster_id                   = var.cluster_id
  tenant_id                    = var.tenant_id
  vpc_id                       = var.vpc_id
  subnet_id                    = var.subnet_id
  slurm_api_port               = var.slurm_api_port
  head_node_instance_id        = var.head_node_instance_id
  clusterra_service_network_id = var.clusterra_service_network_id
  clusterra_account_id         = var.clusterra_account_id
}

# NOTE: Events (EventBridge) are now integrated into module.connectivity
# The old cluster-events module (SQS/Lambda) has been removed

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

output "install_hooks_command" {
  description = "Run this on head node to install event hooks (uses Clusterra API instead of SQS)"
  value       = "sudo /opt/clusterra/install-hooks.sh ${var.clusterra_api_url} ${var.cluster_id} ${var.tenant_id}"
}

# VPC Lattice outputs (replaces PrivateLink outputs)
output "lattice_service_endpoint" {
  description = "VPC Lattice service DNS endpoint for Clusterra to connect"
  value       = module.connectivity.lattice_service_endpoint
}

output "lattice_service_network_id" {
  description = "VPC Lattice service network ID (shared via RAM with Clusterra)"
  value       = var.clusterra_service_network_id
}
