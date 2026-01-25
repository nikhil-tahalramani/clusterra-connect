variable "region" {
  description = "AWS Region"
  type        = string
}

variable "cluster_name" {
  description = "Cluster Name"
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

variable "slurm_jwt_secret_name" {
  description = "Secrets Manager secret name for Slurm JWT"
  type        = string
}

variable "slurm_api_port" {
  description = "Port for Slurm REST API"
  type        = number
}
