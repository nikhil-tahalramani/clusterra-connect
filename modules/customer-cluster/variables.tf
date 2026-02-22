variable "cluster_name" {
  description = "Name of the K8s cluster (used for tagging and Karpenter discovery)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the node runs"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the node + karpenter.sh/discovery tag"
  type        = string
}

variable "ssh_key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "instance_type" {
  description = "Instance type for the K3s control node"
  type        = string
  default     = "t4g.small"
}

variable "enable_spot" {
  description = "Use EC2 Spot pricing."
  type        = bool
  default     = false
}
