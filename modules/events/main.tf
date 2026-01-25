# Clusterra Events Module
#
# Creates SQS queue, CloudWatch Event Rules, and Event Shipper Lambda
# Deployed in CUSTOMER's AWS account

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# SQS QUEUE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "events" {
  name                       = "clusterra-events-${var.cluster_name}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400  # 1 day
  receive_wait_time_seconds  = 20     # Long polling

  tags = {
    Name      = "clusterra-events-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
    Cluster   = var.cluster_name
  }
}

# Dead letter queue for failed messages
resource "aws_sqs_queue" "events_dlq" {
  name                      = "clusterra-events-${var.cluster_name}-dlq"
  message_retention_seconds = 604800  # 7 days

  tags = {
    Name      = "clusterra-events-${var.cluster_name}-dlq"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_sqs_queue_redrive_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3
  })
}

# Allow CloudWatch Events to send to SQS
resource "aws_sqs_queue_policy" "allow_cloudwatch" {
  queue_url = aws_sqs_queue.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.events.arn
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH EVENT RULES
# ─────────────────────────────────────────────────────────────────────────────

# EC2 instance state changes (head node start/stop)
resource "aws_cloudwatch_event_rule" "ec2_state" {
  name        = "clusterra-ec2-state-${var.cluster_name}"
  description = "Capture EC2 state changes for head node"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["pending", "running", "stopping", "stopped"]
    }
  })

  tags = {
    Name      = "clusterra-ec2-state-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_cloudwatch_event_target" "ec2_to_sqs" {
  rule = aws_cloudwatch_event_rule.ec2_state.name
  arn  = aws_sqs_queue.events.arn
}

# ASG events (compute node launch/terminate)
resource "aws_cloudwatch_event_rule" "asg_events" {
  name        = "clusterra-asg-${var.cluster_name}"
  description = "Capture ASG events for compute nodes"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = [
      "EC2 Instance Launch Successful",
      "EC2 Instance Terminate Successful"
    ]
  })

  tags = {
    Name      = "clusterra-asg-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_cloudwatch_event_target" "asg_to_sqs" {
  rule = aws_cloudwatch_event_rule.asg_events.name
  arn  = aws_sqs_queue.events.arn
}

# Spot interruption warnings
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "clusterra-spot-${var.cluster_name}"
  description = "Capture spot interruption warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name      = "clusterra-spot-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_cloudwatch_event_target" "spot_to_sqs" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.events.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# LAMBDA FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

resource "aws_lambda_function" "event_shipper" {
  function_name = "clusterra-event-shipper-${var.cluster_name}"
  description   = "Ships cluster events to Clusterra API"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128

  role = aws_iam_role.lambda_execution.arn

  environment {
    variables = {
      CLUSTER_ID        = var.cluster_id
      TENANT_ID         = var.tenant_id
      CLUSTERRA_API_URL = var.clusterra_api_url
    }
  }

  tags = {
    Name      = "clusterra-event-shipper-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

# SQS trigger for Lambda
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.event_shipper.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLES
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_execution" {
  name = "clusterra-lambda-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name      = "clusterra-lambda-${var.cluster_name}"
    ManagedBy = "OpenTOFU"
  }
}

resource "aws_iam_role_policy" "lambda_sqs" {
  name = "clusterra-lambda-sqs"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# IAM policy for Slurm hooks to send to SQS
resource "aws_iam_policy" "slurm_sqs_send" {
  name        = "clusterra-slurm-sqs-${var.cluster_name}"
  description = "Allow Slurm hooks to send events to SQS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.events.arn
    }]
  })
}
