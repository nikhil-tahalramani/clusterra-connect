variable "cluster_name" {
  description = "Name of the K8s cluster (used for tagging and Karpenter discovery)"
  type        = string
}

variable "cluster_endpoint" {
  description = "The endpoint of the customer K3s cluster"
  type        = string
}

variable "head_node_public_ip" {
  description = "Public IP of the customer cluster head node for SSH"
  type        = string
}

variable "ssh_key_path" {
  description = "Path to the SSH private key"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_user" {
  description = "SSH user"
  type        = string
  default     = "ubuntu"
}

variable "karpenter_node_role_name" {
  description = "Name of the IAM Role that Karpenter instances will assume"
  type        = string
}

variable "slurmctld_host" {
  description = "Public IP or DNS hostname of the central slurmctld/slurmrestd server"
  type        = string
}

variable "slurmrestd_port" {
  description = "NodePort on the central cluster exposing slurmrestd"
  type        = number
  default     = 30767
}

variable "prometheus_endpoint" {
  description = "Public URL of the central Prometheus server"
  type        = string
}

variable "tenant_id" {
  description = "Clusterra tenant ID"
  type        = string
}

variable "prometheus_bearer_token_secret_name" {
  description = "Name of the secret in AWS Secrets Manager containing the Prometheus bearer token"
  type        = string
}
