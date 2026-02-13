variable "region" {
  description = "AWS Region"
  type        = string
}

variable "cluster_name" {
  description = "Cluster Name (matches ParallelCluster name)"
  type        = string
}


variable "vpc_id" {
  description = "VPC ID where the head node runs"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID (same as head node)"
  type        = string
}

variable "slurm_api_port" {
  description = "Port where slurmrestd listens"
  type        = number
  default     = 6830
}

variable "head_node_instance_id" {
  description = "Instance ID of head node (optional - auto-discovered via pcluster tags if not provided)"
  type        = string
  default     = ""
}

variable "clusterra_account_id" {
  description = "Clusterra's AWS account ID for cross-account access"
  type        = string
}

variable "clusterra_service_network_id" {
  description = "Clusterra's VPC Lattice Service Network ID (from Control Plane)"
  type        = string
}

variable "cluster_id" {
  description = "Clusterra cluster ID (8 chars: clusa1b2)"
  type        = string
}

variable "tenant_id" {
  description = "Clusterra tenant ID for event routing"
  type        = string
}

variable "clusterra_api_endpoint" {
  description = "Clusterra API endpoint (e.g., api.clusterra.cloud) - DEPRECATED for events, used for other calls?"
  type        = string
  default     = "api.clusterra.cloud"
}

variable "clusterra_region" {
  description = "Region where Clusterra SaaS runs"
  type        = string
  default     = "ap-south-1"
}

variable "clusterra_bus_name" {
  description = "Name of the Clusterra SaaS Event Bus"
  type        = string
  default     = "clusterra"
}
