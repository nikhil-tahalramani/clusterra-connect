# Clusterra Connect Module (VPC Lattice)
#
# Creates the VPC Lattice connectivity layer for Clusterra to access the cluster's Slurm API:
# 1. VPC Lattice Service → Head Node port 6830 (slurmrestd)
# 2. VPC Lattice Service Network → Cross-account access via AWS RAM
# 3. IAM Role → Allows Clusterra to assume role and read JWT secret
#
# Deployed in: CUSTOMER's AWS account

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS & LOCALS
# ─────────────────────────────────────────────────────────────────────────────

locals {
  cluster_short_id     = "cust-${substr(sha256(var.cluster_name), 0, 8)}"  # Short ID for AWS resources with name limits
  clusterra_account_id = var.clusterra_account_id
}

# Generate a unique customer ID for resource naming
resource "random_id" "customer" {
  byte_length = 4
}

locals {
  customer_id = "cust-${random_id.customer.hex}"
  
  # Use provided instance_id or look it up via tags
  target_instance_id = var.head_node_instance_id != "" ? var.head_node_instance_id : (
    length(data.aws_instances.head_node) > 0 && length(data.aws_instances.head_node[0].ids) > 0 
    ? data.aws_instances.head_node[0].ids[0] 
    : null
  )
}

# ─────────────────────────────────────────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Create JWT Secret for Clusterra integration
resource "random_password" "slurm_jwt_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "slurm_jwt" {
  name                    = "clusterra-slurm-jwt-${var.cluster_name}"
  description             = "Slurm JWT HS256 key for Clusterra authentication"
  recovery_window_in_days = 30  # Production-safe: 30-day recovery window

  tags = {
    Purpose   = "Clusterra Slurm authentication"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_secretsmanager_secret_version" "slurm_jwt" {
  secret_id     = aws_secretsmanager_secret.slurm_jwt.id
  secret_string = random_password.slurm_jwt_key.result
}

# Find the head node by ParallelCluster tags (ONLY if head_node_instance_id is not provided)
data "aws_instances" "head_node" {
  count = var.head_node_instance_id == "" ? 1 : 0

  filter {
    name   = "tag:parallelcluster:cluster-name"
    values = [var.cluster_name]
  }
  filter {
    name   = "tag:parallelcluster:node-type"
    values = ["HeadNode"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# Get head node instance details for IP-based target group
data "aws_instance" "head_node" {
  count       = local.target_instance_id != null ? 1 : 0
  instance_id = local.target_instance_id
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY GROUP
# ─────────────────────────────────────────────────────────────────────────────

# Get VPC Lattice managed prefix list for security group rules
data "aws_ec2_managed_prefix_list" "vpc_lattice" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${data.aws_region.current.name}.vpc-lattice"]
  }
}

resource "aws_security_group" "lattice_target" {
  # checkov:skip=CKV2_AWS_5:Security group is attached to head node for Lattice access
  name        = "clusterra-lattice-sg-${var.cluster_name}"
  description = "Allow slurmrestd traffic from VPC Lattice to head node"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.slurm_api_port
    to_port         = var.slurm_api_port
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.vpc_lattice.id]
    description     = "Allow slurmrestd traffic from VPC Lattice"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
    description = "Allow all outbound to VPC"
  }

  tags = {
    Name      = "clusterra-lattice-sg-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE SERVICE NETWORK
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_service_network" "clusterra" {
  name      = "clusterra-${local.cluster_short_id}"
  auth_type = "AWS_IAM"

  tags = {
    Name      = "clusterra-${local.customer_id}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# Associate the service network with the VPC
resource "aws_vpclattice_service_network_vpc_association" "head_node_vpc" {
  vpc_identifier             = var.vpc_id
  service_network_identifier = aws_vpclattice_service_network.clusterra.id
  security_group_ids         = [aws_security_group.lattice_target.id]

  tags = {
    Name      = "clusterra-vpc-assoc-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE SERVICE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_service" "slurm_api" {
  name      = "clusterra-slurm-${local.cluster_short_id}"
  auth_type = "AWS_IAM"  # Use IAM for cross-account auth

  tags = {
    Name      = "clusterra-slurm-${local.customer_id}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# Associate service with service network
resource "aws_vpclattice_service_network_service_association" "slurm_api" {
  service_identifier         = aws_vpclattice_service.slurm_api.id
  service_network_identifier = aws_vpclattice_service_network.clusterra.id

  tags = {
    Name      = "clusterra-svc-assoc-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE TARGET GROUP
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_target_group" "slurm_api" {
  name = "clusterra-tg-${local.cluster_short_id}"
  type = "IP"

  config {
    port             = var.slurm_api_port
    protocol         = "HTTP"
    vpc_identifier   = var.vpc_id
    ip_address_type  = "IPV4"
    protocol_version = "HTTP1"

    health_check {
      enabled                   = true
      protocol                  = "HTTP"
      path                      = "/slurm/v0.0.42/ping"  # Slurmrestd health endpoint
      port                      = var.slurm_api_port
      healthy_threshold_count   = 2
      unhealthy_threshold_count = 3
      matcher {
        value = "200"
      }
    }
  }

  tags = {
    Name      = "clusterra-tg-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# Register head node IP as target
resource "aws_vpclattice_target_group_attachment" "head_node" {
  count = local.target_instance_id != null ? 1 : 0

  target_group_identifier = aws_vpclattice_target_group.slurm_api.id

  target {
    id   = data.aws_instance.head_node[0].private_ip
    port = var.slurm_api_port
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE LISTENER
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_listener" "slurm_api" {
  name               = "clusterra-listener-${local.cluster_short_id}"
  protocol           = "HTTPS"  # TLS termination at Lattice (recommended for slurmrestd)
  port               = 443
  service_identifier = aws_vpclattice_service.slurm_api.id

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.slurm_api.id
        weight                  = 100
      }
    }
  }

  tags = {
    Name      = "clusterra-listener-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE AUTH POLICY
# ─────────────────────────────────────────────────────────────────────────────

# Allow Clusterra account to invoke the service
resource "aws_vpclattice_auth_policy" "allow_clusterra" {
  resource_identifier = aws_vpclattice_service.slurm_api.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowClusterraAccess"
        Effect    = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.clusterra_account_id}:root"
        }
        Action   = "vpc-lattice-svcs:Invoke"
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS RAM RESOURCE SHARE (Cross-Account Access)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ram_resource_share" "clusterra_service_network" {
  name                      = "clusterra-${var.cluster_name}"
  allow_external_principals = true  # Allow sharing with Clusterra account

  tags = {
    Name      = "clusterra-ram-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# Share the service network with Clusterra account
resource "aws_ram_resource_association" "service_network" {
  resource_arn       = aws_vpclattice_service_network.clusterra.arn
  resource_share_arn = aws_ram_resource_share.clusterra_service_network.arn
}

# Associate Clusterra account as principal
resource "aws_ram_principal_association" "clusterra" {
  principal          = local.clusterra_account_id
  resource_share_arn = aws_ram_resource_share.clusterra_service_network.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLE FOR CLUSTERRA CROSS-ACCOUNT ACCESS
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "clusterra_access" {
  name = "clusterra-access-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.clusterra_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "clusterra-${var.cluster_name}"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "clusterra-access-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

resource "aws_iam_role_policy" "secrets_access" {
  name = "clusterra-secrets-access"
  role = aws_iam_role.clusterra_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadJWTSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.slurm_jwt.arn
      }
    ]
  })
}

# EC2 permissions for start/stop cluster
resource "aws_iam_role_policy" "ec2_access" {
  name = "clusterra-ec2-access"
  role = aws_iam_role.clusterra_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeAllInstances"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageClusterInstances"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/parallelcluster:cluster-name" = var.cluster_name
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS - Values for Clusterra API registration
# ─────────────────────────────────────────────────────────────────────────────

output "clusterra_onboarding" {
  description = "Copy ALL of these values to Clusterra console or use for API registration"
  value = {
    cluster_name               = var.cluster_name
    region                     = data.aws_region.current.name
    aws_account_id             = data.aws_caller_identity.current.account_id
    # VPC Lattice endpoints (replaces vpc_endpoint_service)
    lattice_service_endpoint   = aws_vpclattice_service.slurm_api.dns_entry[0].domain_name
    lattice_service_network_id = aws_vpclattice_service_network.clusterra.id
    slurm_port                 = var.slurm_api_port
    slurm_jwt_secret_arn       = aws_secretsmanager_secret.slurm_jwt.arn
    role_arn                   = aws_iam_role.clusterra_access.arn
    external_id                = "clusterra-${var.cluster_name}"
    head_node_instance_id      = local.target_instance_id
  }
}

output "lattice_service_endpoint" {
  description = "VPC Lattice service DNS endpoint for Clusterra to connect"
  value       = aws_vpclattice_service.slurm_api.dns_entry[0].domain_name
}

output "lattice_service_network_id" {
  description = "VPC Lattice service network ID (shared via RAM)"
  value       = aws_vpclattice_service_network.clusterra.id
}

output "iam_role_arn" {
  description = "IAM Role ARN for Clusterra cross-account access"
  value       = aws_iam_role.clusterra_access.arn
}

output "external_id" {
  description = "External ID for STS AssumeRole"
  value       = "clusterra-${var.cluster_name}"
  sensitive   = true
}

output "customer_id" {
  description = "Unique customer ID for this deployment"
  value       = local.customer_id
}

# Keep NLB outputs for backwards compatibility (will be null/empty)
output "nlb_arn" {
  description = "DEPRECATED: NLB ARN (replaced by VPC Lattice)"
  value       = null
}

output "vpc_endpoint_service_name" {
  description = "DEPRECATED: VPC Endpoint Service name (replaced by VPC Lattice)"
  value       = null
}
