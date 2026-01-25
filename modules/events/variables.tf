# Clusterra Events Module Variables

variable "cluster_name" {
  description = "Name of the ParallelCluster"
  type        = string
}

variable "cluster_id" {
  description = "Clusterra cluster ID (clus_xxx)"
  type        = string
}

variable "tenant_id" {
  description = "Clusterra tenant ID (ten_xxx)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "clusterra_api_url" {
  description = "Clusterra API URL"
  type        = string
  default     = "https://api.clusterra.cloud"
}

variable "head_node_instance_id" {
  description = "Head node EC2 instance ID (for filtering CloudWatch events)"
  type        = string
  default     = ""
}
