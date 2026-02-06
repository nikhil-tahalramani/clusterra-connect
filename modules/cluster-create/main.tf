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
  default     = "t3.medium"
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

variable "secondary_subnet_id" {
  description = "Second subnet (different AZ) for Aurora"
  type        = string
}

# (Storage variables removed)

# ─── Data Sources ──────────────────────────────────────────────────────────

# ─── Data Sources ──────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Auto-discover Private Subnets for Aurora (Requires 2 AZs)
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  # Private subnets typically don't map public IPs on launch
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

# ─── Secrets Manager for Slurm DB Password ─────────────────────────────────

resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "slurm_db_password" {
  name_prefix             = "slurm-db-password-${var.cluster_name}-"
  description             = "Password for Slurm accounting database user"
  recovery_window_in_days = 0 # Immediate deletion for demo/dev
  # checkov:skip=CKV_AWS_149:Default KMS key is sufficient for this module

}

resource "aws_secretsmanager_secret_version" "slurm_db_password" {
  secret_id     = aws_secretsmanager_secret.slurm_db_password.id
  secret_string = random_password.db_password.result
}

# ─── Aurora Serverless v2 (MySQL) ──────────────────────────────────────────

resource "aws_security_group" "aurora" {
  name        = "${var.cluster_name}-aurora-sg"
  description = "Allow SlurmDB traffic from Head Node"
  vpc_id      = var.vpc_id

  # Inbound MySQL from Head Node Subnet
  ingress {
    description = "Allow MySQL from Head Node"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.head_node.cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# Get subnet details to check AZs
data "aws_subnet" "head_node" {
  id = var.subnet_id
}

resource "aws_db_subnet_group" "slurm_db" {
  name        = "${var.cluster_name}-db-subnet-group"
  description = "Allowed subnets for Aurora Serverless v2"
  # Use provided subnet + secondary subnet + auto-discovered private subnets
  subnet_ids = distinct(concat([var.subnet_id, var.secondary_subnet_id], data.aws_subnets.private.ids))

  tags = {
    Name = "${var.cluster_name}-db-subnet-group"
  }
}

resource "aws_rds_cluster" "slurm_db" {
  cluster_identifier = "${var.cluster_name}-db-cluster"
  engine             = "aurora-mysql"
  engine_mode        = "provisioned"
  engine_version     = "8.0.mysql_aurora.3.08.0"
  database_name      = "slurm_acct_db"
  master_username    = "slurm"
  master_password    = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.slurm_db.name
  vpc_security_group_ids = [aws_security_group.aurora.id]
  skip_final_snapshot    = true

  # Security & Compliance
  storage_encrypted                   = true
  iam_database_authentication_enabled = true
  copy_tags_to_snapshot               = true
  backtrack_window                    = 3600 # 1 hour
  deletion_protection                 = false # For easy teardown in this module

  # Logging
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]

  # checkov:skip=CKV_AWS_327:Default KMS key is sufficient
  # checkov:skip=CKV_AWS_149:Default KMS key is sufficient


  serverlessv2_scaling_configuration {
    min_capacity = 0.0 # Scales to 0 when idle (auto-pause)
    max_capacity = 2.0
  }

  lifecycle {
    ignore_changes = [
      availability_zones # Ignore AZ changes to prevent recreation
    ]
  }
}

resource "aws_rds_cluster_instance" "slurm_db_instance" {
  cluster_identifier = aws_rds_cluster.slurm_db.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.slurm_db.engine
  engine_version     = aws_rds_cluster.slurm_db.engine_version
}


# ─── Cluster Configuration ─────────────────────────────────────────────────

locals {
  # Common settings for queues
  queue_networking = {
    SubnetIds = [var.subnet_id]
  }

  common_iam = [
    { Policy = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" },
    { Policy = "arn:aws:iam::aws:policy/SecretsManagerReadWrite" }, # Needed for DB password
    { Policy = "arn:aws:iam::aws:policy/AmazonSQSFullAccess" }
  ]

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
      Iam = {
        AdditionalIamPolicies = local.common_iam
      }
      LocalStorage = {
        RootVolume = {
          Size = 50
        }
      }
    }

    Scheduling = {
      Scheduler = "slurm"
      SlurmSettings = {
        ScaledownIdletime = 5
        Database = {
          Uri               = "${aws_rds_cluster.slurm_db.endpoint}:3306"
          UserName          = "slurm"
          PasswordSecretArn = aws_secretsmanager_secret.slurm_db_password.arn
        }
      }
      SlurmQueues = [
        # 1. Compute Queue (General Purpose)
        {
          Name = "compute"
          ComputeResources = [
            {
              Name         = "spot"
              InstanceType = var.compute_instance_type
              MinCount     = 0
              MaxCount     = 10
            },
            {
              Name         = "c5-4xl"
              InstanceType = "c5.4xlarge"
              MinCount     = 0
              MaxCount     = 10
            }
          ]
          CapacityType = "SPOT"
          Networking   = { SubnetIds = [var.subnet_id] }
        },
        # 2. GPU Queue (ML Training)
        {
          Name = "gpu"
          ComputeResources = [
            {
              Name         = "g5-xl"
              InstanceType = "g5.xlarge"
              MinCount     = 0
              MaxCount     = 4
            },
            {
              Name         = "g5-2xl"
              InstanceType = "g5.2xlarge"
              MinCount     = 0
              MaxCount     = 4
            }
          ]
          CapacityType = "SPOT"
          Networking   = { SubnetIds = [var.subnet_id] }
        },
        # 3. Memory Queue (EDA)
        {
          Name = "memory"
          ComputeResources = [
            {
              Name         = "r6i-4xl"
              InstanceType = "r6i.4xlarge"
              MinCount     = 0
              MaxCount     = 4
            },
            {
              Name         = "x2idn-16xl"
              InstanceType = "x2idn.16xlarge"
              MinCount     = 0
              MaxCount     = 4
            }
          ]
          CapacityType = "SPOT"
          Networking   = { SubnetIds = [var.subnet_id] }
        },
        # 4. On-Demand Queue (Critical Workloads)
        {
          Name = "ondemand"
          ComputeResources = [
            {
              Name         = "c5-xl-od"
              InstanceType = "c5.xlarge"
              MinCount     = 0
              MaxCount     = 4
            },
            {
              Name         = "r6i-xl-od"
              InstanceType = "r6i.xlarge"
              MinCount     = 0
              MaxCount     = 4
            },
            {
              Name         = "g5-xl-od"
              InstanceType = "g5.xlarge"
              MinCount     = 0
              MaxCount     = 4
            }
          ]
          CapacityType = "ONDEMAND"
          Networking   = { SubnetIds = [var.subnet_id] }
        }
      ]
    }
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

output "deploy_command" {
  description = "Command to create the cluster (run after tofu apply)"
  value       = "pcluster create-cluster --cluster-name ${var.cluster_name} --cluster-configuration ${local_file.cluster_config.filename} --region ${var.region}"
}

output "head_node_ip_command" {
  description = "Command to get head node private IP (after cluster is created)"
  value       = "pcluster describe-cluster --cluster-name ${var.cluster_name} --region ${var.region} | jq -r '.headNode.privateIpAddress'"
}
