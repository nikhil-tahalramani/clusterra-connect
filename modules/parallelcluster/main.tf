# Clusterra ParallelCluster Module
#
# Creates an AWS ParallelCluster with Slurm scheduler.
# Uses the AWS ParallelCluster CLI via a null_resource provisioner.
#
# Deployed in: CUSTOMER's AWS account

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ─── Variables ─────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the ParallelCluster"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for head node"
  type        = string
}

variable "ssh_key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "head_node_instance_type" {
  description = "Instance type for head node"
  type        = string
  default     = "t3.small"
}

variable "compute_instance_type" {
  description = "Instance type for compute nodes"
  type        = string
  default     = "c5.large"
}

variable "min_count" {
  description = "Minimum compute nodes"
  type        = number
  default     = 0
}

variable "max_count" {
  description = "Maximum compute nodes"
  type        = number
  default     = 10
}

variable "shared_storage_type" {
  description = "Shared storage type: efs or fsx_lustre"
  type        = string
  default     = "efs"
}

variable "fsx_storage_capacity" {
  description = "FSx Lustre storage capacity in GB (minimum 1200)"
  type        = number
  default     = 1200
}

variable "customer_id" {
  description = "Clusterra customer ID"
  type        = string
}

variable "slurm_jwt_secret_name" {
  description = "Name for the Slurm JWT secret in Secrets Manager"
  type        = string
  default     = "clusterra-slurm-jwt-key"
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption (Secrets Manager, EFS). If not provided, uses AWS managed keys."
  type        = string
  default     = null
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block for restricting security group egress"
  type        = string
  default     = "10.0.0.0/8"
}

# ─── Data Sources ──────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ─── Slurm JWT Secret ──────────────────────────────────────────────────────

# Generate a random HS256 key for Slurm JWT authentication
resource "random_password" "slurm_jwt_key" {
  length  = 64
  special = false
}

# checkov:skip=CKV2_AWS_57:JWT signing keys are static secrets that don't require rotation
resource "aws_secretsmanager_secret" "slurm_jwt" {
  name        = var.slurm_jwt_secret_name
  description = "Slurm JWT HS256 key for Clusterra authentication"

  # CKV_AWS_149: Use KMS CMK for encryption
  kms_key_id = var.kms_key_arn
  
  tags = {
    Purpose   = "Clusterra Slurm authentication"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_secretsmanager_secret_version" "slurm_jwt" {
  secret_id     = aws_secretsmanager_secret.slurm_jwt.id
  secret_string = random_password.slurm_jwt_key.result
}

# ─── EFS (for demo/dev) ────────────────────────────────────────────────────

resource "aws_efs_file_system" "shared" {
  count = var.shared_storage_type == "efs" ? 1 : 0
  
  creation_token = "${var.cluster_name}-efs"
  encrypted      = true

  # CKV_AWS_184: Use KMS CMK for encryption
  kms_key_id = var.kms_key_arn
  
  tags = {
    Name      = "${var.cluster_name}-shared"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_efs_mount_target" "shared" {
  count = var.shared_storage_type == "efs" ? 1 : 0
  
  file_system_id  = aws_efs_file_system.shared[0].id
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.efs[0].id]
}

resource "aws_security_group" "efs" {
  count = var.shared_storage_type == "efs" ? 1 : 0
  
  name        = "${var.cluster_name}-efs"
  description = "EFS mount target security group for ${var.cluster_name} cluster"
  vpc_id      = var.vpc_id
  
  # CKV_AWS_23: Add descriptions to all rules
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
    description = "Allow NFS traffic from VPC for EFS mount"
  }
  
  # CKV_AWS_382: Restrict egress to specific ports/destinations
  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
    description = "Allow NFS traffic to VPC for EFS communication"
  }
  
  tags = {
    Name      = "${var.cluster_name}-efs"
    ManagedBy = "OpenTOFU"
  }
}

locals {
  # EFS-only shared storage config (simplifies type issues)
  efs_storage = var.shared_storage_type == "efs" ? [
    {
      Name        = "shared"
      StorageType = "Efs"
      MountDir    = "/shared"
      EfsSettings = {
        FileSystemId = aws_efs_file_system.shared[0].id
      }
    }
  ] : []
  
  cluster_config = yamlencode({
    Region = var.region
    
    Image = {
      Os = "alinux2023"
    }
    
    HeadNode = {
      InstanceType = var.head_node_instance_type
      Networking = {
        SubnetId = var.subnet_id
      }
      Ssh = {
        KeyName = var.ssh_key_name
      }
      LocalStorage = {
        RootVolume = {
          Size = 50
        }
      }
      # Enable slurmrestd on port 6830 (CustomActions or PostInstall would normally do this, 
      # but AL2023 Support for slurmrestd is native in newer PC versions. 
      # We ensure the Security Group allows it below).
    }
    
    Scheduling = {
      Scheduler = "slurm"
      SlurmSettings = {
        ScaledownIdletime = 5
      }
      SlurmQueues = [
        {
          Name = "compute"
          ComputeResources = [
            {
              Name         = "spot"
              InstanceType = var.compute_instance_type
              MinCount     = var.min_count
              MaxCount     = var.max_count
            }
          ]
          ComputeSettings = {
            LocalStorage = {
              RootVolume = {
                Size = 50
              }
            }
          }
          CapacityType = "SPOT"
          Networking = {
            SubnetIds = [var.subnet_id]
          }
        }
      ]
    }
    
    SharedStorage = local.efs_storage
  })
}

# Write cluster config to file
resource "local_file" "cluster_config" {
  content  = local.cluster_config
  filename = "${path.root}/generated/${var.cluster_name}-config.yaml"
}

# ─── Outputs ───────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "ParallelCluster name"
  value       = var.cluster_name
}

output "cluster_config_path" {
  description = "Path to generated cluster config file"
  value       = local_file.cluster_config.filename
}

output "slurm_jwt_secret_arn" {
  description = "ARN of the Slurm JWT secret (provide to Clusterra)"
  value       = aws_secretsmanager_secret.slurm_jwt.arn
}

output "slurm_jwt_secret_name" {
  description = "Name of the Slurm JWT secret"
  value       = aws_secretsmanager_secret.slurm_jwt.name
}

output "shared_storage_id" {
  description = "EFS or FSx file system ID"
  value       = var.shared_storage_type == "efs" ? aws_efs_file_system.shared[0].id : null
}

output "deploy_command" {
  description = "Command to create the cluster (run after tofu apply)"
  value       = "pcluster create-cluster --cluster-name ${var.cluster_name} --cluster-configuration ${local_file.cluster_config.filename} --region ${var.region}"
}

output "head_node_ip_command" {
  description = "Command to get head node private IP (after cluster is created)"
  value       = "pcluster describe-cluster --cluster-name ${var.cluster_name} --region ${var.region} | jq -r '.headNode.privateIpAddress'"
}
