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
  clusterra_account_id = var.clusterra_account_id
}

locals {
  # Instance ID is always provided via tfvars (from CloudFormation lookup in install.py)
  # This works regardless of instance state (running, stopped, etc.)
  target_instance_id = var.head_node_instance_id != "" ? var.head_node_instance_id : null
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
  # checkov:skip=CKV2_AWS_57:Automatic rotation not needed for static JWT
  # checkov:skip=CKV_AWS_149:Default KMS key is sufficient
  name                    = "clusterra-jwt-${var.cluster_id}"
  description             = "Slurm JWT HS256 key for Clusterra authentication"
  recovery_window_in_days = 0 # Immediate deletion for dev/demo - avoids "scheduled for deletion" conflicts

  tags = {
    Purpose   = "Clusterra Slurm authentication"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

resource "aws_secretsmanager_secret_version" "slurm_jwt" {
  secret_id     = aws_secretsmanager_secret.slurm_jwt.id
  secret_string = random_password.slurm_jwt_key.result
}

# Note: Head node instance ID is always provided via tfvars.
# The install.py script fetches it from CloudFormation, which works regardless of instance state.

# Get head node instance details for IP-based target group
data "aws_instance" "head_node" {
  count       = local.target_instance_id != null ? 1 : 0
  instance_id = local.target_instance_id
}

# Get head node IAM instance profile
data "aws_iam_instance_profile" "head_node" {
  count = local.target_instance_id != null && length(data.aws_instance.head_node) > 0 ? 1 : 0
  # Instance profile can be just a name or contain a path - extract the name part
  name = element(split("/", data.aws_instance.head_node[0].iam_instance_profile), length(split("/", data.aws_instance.head_node[0].iam_instance_profile)) - 1)
}

# Allow head node role to read JWT secret (required for slurmrestd setup)
resource "aws_iam_role_policy" "head_node_jwt_access" {
  count = length(data.aws_iam_instance_profile.head_node) > 0 ? 1 : 0

  name = "clusterra-jwt-access-${var.cluster_id}"
  role = data.aws_iam_instance_profile.head_node[0].role_name

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

# NOTE: SSM policy (AmazonSSMManagedInstanceCore) is attached by install.py's
# ensure_ssm_permissions() function BEFORE tofu apply runs. This keeps the policy
# outside of Terraform's management, so cleanup_resources() won't remove it during
# rollback - avoiding the chicken-and-egg problem where SSM is needed to reinstall.

# Note: Head node Slurm hooks use curl to send events directly to Clusterra API

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

# Find the existing Head Node Security Group created by ParallelCluster
data "aws_security_group" "head_node" {
  count = local.target_instance_id != null ? 1 : 0
  filter {
    name   = "tag:parallelcluster:cluster-name"
    values = [var.cluster_name]
  }
  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["HeadNodeSecurityGroup"]
  }
}

# Inject Ingress Rule for VPC Lattice into the EXISTING Head Node SG
resource "aws_security_group_rule" "lattice_ingress" {
  count = length(data.aws_security_group.head_node) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = var.slurm_api_port
  to_port           = var.slurm_api_port
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.vpc_lattice.id]
  security_group_id = data.aws_security_group.head_node[0].id
  description       = "Allow slurmrestd traffic from VPC Lattice (Clusterra)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSM CONFIGURATION (JWT Key Setup)
# ─────────────────────────────────────────────────────────────────────────────

# Create SSM Document content
resource "aws_ssm_document" "setup_slurmrestd" {
  name          = "clusterra-setup-${var.cluster_id}"
  document_type = "Command"
  target_type   = "/aws/ec2/instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure slurmrestd with JWT for Clusterra"
    parameters = {
      SecretArn = {
        type        = "String"
        description = "ARN of the JWT Secret"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "configureSlurmrestd"
        inputs = {
          timeoutSeconds = "300"
          runCommand = [
            # Export SSM parameter as environment variable (critical for script to receive JWT ARN)
            "export SecretArn='{{ SecretArn }}'",
            # Embed the script content directly to avoid upload complexity
            base64decode(base64encode(file("${path.module}/scripts/setup-slurmrestd.sh")))
          ]
        }
      }
    ]
  })

  tags = {
    Name      = "clusterra-setup-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# Trigger SSM Association to run the script on the Head Node
resource "aws_ssm_association" "configure_head_node" {
  count = local.target_instance_id != null ? 1 : 0

  name = aws_ssm_document.setup_slurmrestd.name

  targets {
    key    = "InstanceIds"
    values = [local.target_instance_id]
  }

  parameters = {
    SecretArn = aws_secretsmanager_secret.slurm_jwt.arn
  }

  depends_on = [
    aws_iam_role_policy.head_node_jwt_access, # Ensure role policy is attached first
    aws_secretsmanager_secret_version.slurm_jwt,
    aws_security_group_rule.lattice_ingress
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE SERVICE NETWORK (Shared from Clusterra Control Plane)
# ─────────────────────────────────────────────────────────────────────────────
# NOTE: Service Network is created and shared by Clusterra Control Plane.
# Customer only needs to create a Service and associate it with the shared network.
# The network ID is passed via var.clusterra_service_network_id


# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE SERVICE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_service" "slurm_api" {
  name      = "clusterra-svc-${var.cluster_id}"
  auth_type = "NONE" # Disable IAM auth to allow Authorization header pass-through

  tags = {
    Name      = "clusterra-svc-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# NOTE: Service Network Association is NOT created here.
# Clusterra API handles this after:
#   1. Adding customer account to RAM share
#   2. Customer accepting RAM invitation
#   3. API calling lattice.create_service_network_service_association()
# See: POST /v1/internal/connect -> _setup_lattice_cross_account()

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE TARGET GROUP
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_target_group" "slurm_api" {
  name = "clusterra-tg-${var.cluster_id}"
  type = "INSTANCE"

  config {
    port             = var.slurm_api_port
    protocol         = "HTTP"
    vpc_identifier   = var.vpc_id
    ip_address_type  = "IPV4"
    protocol_version = "HTTP1"

    health_check {
      enabled                   = true
      protocol                  = "HTTP"
      path                      = "/slurm/v0.0.42/ping" # Slurmrestd health endpoint
      port                      = var.slurm_api_port
      healthy_threshold_count   = 2
      unhealthy_threshold_count = 3
      matcher {
        value = "200,401"
      }
    }
  }

  tags = {
    Name      = "clusterra-tg-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# Register head node IP as target
resource "aws_vpclattice_target_group_attachment" "head_node" {
  count = local.target_instance_id != null ? 1 : 0

  target_group_identifier = aws_vpclattice_target_group.slurm_api.id

  target {
    id   = local.target_instance_id
    port = var.slurm_api_port
  }

  # Timeouts to handle AWS propagation delays
  timeouts {
    create = "10m"
    delete = "10m"
  }

  # Note: lifecycle.replace_triggered_by cannot reference locals, only resources
  # The attachment will be recreated via count condition when instance changes
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC LATTICE LISTENER
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpclattice_listener" "slurm_api" {
  name               = "clusterra-ls-${var.cluster_id}"
  protocol           = "HTTPS" # TLS termination at Lattice (recommended for slurmrestd)
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
    Name      = "clusterra-ls-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }

  # CRITICAL: Listener must depend on attachment so destroy order is:
  # 1. Listener (removes target group reference)
  # 2. Attachment (now safe since target group is unused)
  # 3. Target Group
  # This prevents the 'TargetGroupNotInUse' destroy error
  depends_on = [aws_vpclattice_target_group_attachment.head_node]
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
        Sid    = "AllowClusterraAccess"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${local.clusterra_account_id}:root",
            "arn:aws:iam::${local.clusterra_account_id}:role/clusterra-bridge-lambda-role"
          ]
        }
        Action   = "vpc-lattice-svcs:Invoke"
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# NOTE: RAM Resource Share is no longer needed here.
# The Service Network is shared FROM Clusterra TO customers (not vice versa).
# Customer accepts the share implicitly when associating their Service.
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLE FOR CLUSTERRA CROSS-ACCOUNT ACCESS
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "clusterra_access" {
  # checkov:skip=CKV_AWS_61:AssumeRole strictly scoped to Clusterra account via Trust Policy
  name = "clusterra-role-${var.cluster_id}"

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
            "sts:ExternalId" = "clusterra-${var.cluster_id}"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "clusterra-role-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
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

# SSM permissions for user provisioning (Clusterra token-translator runs sacctmgr via SSM)
resource "aws_iam_role_policy" "ssm_access" {
  name = "clusterra-ssm-access"
  role = aws_iam_role.clusterra_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand"
        ]
        Resource = [
          "arn:aws:ssm:*:*:document/AWS-RunShellScript",
          "arn:aws:ec2:*:*:instance/*"
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/parallelcluster:cluster-name" = var.cluster_name
          }
        }
      },
      {
        Sid    = "SSMGetCommandInvocation"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENTBRIDGE API DESTINATION (Node Events → Clusterra API)
# Sends EC2/ASG events directly to Clusterra API via HTTPS
# ─────────────────────────────────────────────────────────────────────────────

# EventBridge Connection (authentication for API Destination)
resource "aws_cloudwatch_event_connection" "clusterra" {
  name               = "clusterra-events-${var.cluster_id}"
  description        = "Connection to Clusterra API for node events"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "X-Cluster-ID"
      value = var.cluster_id
    }
  }
}

# EventBridge API Destination (targets Clusterra API)
resource "aws_cloudwatch_event_api_destination" "clusterra" {
  name                             = "clusterra-events-${var.cluster_id}"
  description                      = "Send node events to Clusterra API"
  invocation_endpoint              = "https://${var.clusterra_api_endpoint}/v1/internal/events"
  http_method                      = "POST"
  invocation_rate_limit_per_second = 100
  connection_arn                   = aws_cloudwatch_event_connection.clusterra.arn
}

# CloudWatch Rule for EC2/ASG events
resource "aws_cloudwatch_event_rule" "node_events" {
  name        = "clusterra-node-events-${var.cluster_id}"
  description = "Capture EC2 and ASG events for Clusterra"

  event_pattern = jsonencode({
    source = ["aws.ec2", "aws.autoscaling"]
    detail-type = [
      "EC2 Instance State-change Notification",
      "EC2 Instance Launch Successful",
      "EC2 Instance Terminate Successful",
      "EC2 Spot Instance Interruption Warning"
    ]
  })

  tags = {
    Name      = "clusterra-node-events-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# Target: Send events to API Destination with input transformer
resource "aws_cloudwatch_event_target" "to_clusterra" {
  rule      = aws_cloudwatch_event_rule.node_events.name
  target_id = "clusterra-api"
  arn       = aws_cloudwatch_event_api_destination.clusterra.arn
  role_arn  = aws_iam_role.eventbridge.arn

  # Input transformer enriches events with cluster_id and tenant_id
  input_transformer {
    input_paths = {
      detail      = "$.detail"
      detail_type = "$.detail-type"
      source      = "$.source"
      time        = "$.time"
    }
    input_template = <<EOF
{
  "cluster_id": "${var.cluster_id}",
  "tenant_id": "${var.tenant_id}",
  "source": <source>,
  "detail-type": <detail_type>,
  "time": <time>,
  "detail": <detail>
}
EOF
  }
}

# IAM Role for EventBridge to invoke API Destination
resource "aws_iam_role" "eventbridge" {
  name = "clusterra-eventbridge-${var.cluster_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name      = "clusterra-eventbridge-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

resource "aws_iam_role_policy" "eventbridge_invoke" {
  name = "invoke-api-destination"
  role = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["events:InvokeApiDestination"]
      Resource = aws_cloudwatch_event_api_destination.clusterra.arn
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS - Values for Clusterra API registration
# ─────────────────────────────────────────────────────────────────────────────


output "clusterra_onboarding" {
  description = "Copy ALL of these values to Clusterra console or use for API registration"
  value = {
    cluster_name   = var.cluster_name
    region         = data.aws_region.current.name
    aws_account_id = data.aws_caller_identity.current.account_id
    # VPC Lattice endpoints (replaces vpc_endpoint_service)
    lattice_service_endpoint   = aws_vpclattice_service.slurm_api.dns_entry[0].domain_name
    lattice_service_arn        = aws_vpclattice_service.slurm_api.arn
    lattice_service_network_id = var.clusterra_service_network_id
    slurm_port                 = 443 # Lattice listener port (slurmrestd runs on ${var.slurm_api_port} internally)
    slurm_jwt_secret_arn       = aws_secretsmanager_secret.slurm_jwt.arn
    role_arn                   = aws_iam_role.clusterra_access.arn
    external_id                = "clusterra-${var.cluster_id}"
    head_node_instance_id      = local.target_instance_id
  }
}

output "lattice_service_endpoint" {
  description = "VPC Lattice service DNS endpoint for Clusterra to connect"
  value       = aws_vpclattice_service.slurm_api.dns_entry[0].domain_name
}



output "iam_role_arn" {
  description = "IAM Role ARN for Clusterra cross-account access"
  value       = aws_iam_role.clusterra_access.arn
}

output "external_id" {
  description = "External ID for STS AssumeRole"
  value       = "clusterra-${var.cluster_id}"
  sensitive   = true
}

output "customer_id" {
  description = "Unique cluster ID for this deployment"
  value       = var.cluster_id
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
