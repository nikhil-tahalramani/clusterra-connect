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
# DATA SOURCES (for head node role lookup)
# ─────────────────────────────────────────────────────────────────────────────

# Get head node instance details
data "aws_instance" "head_node" {
  count       = var.head_node_instance_id != "" ? 1 : 0
  instance_id = var.head_node_instance_id
}

# Get head node IAM instance profile
data "aws_iam_instance_profile" "head_node" {
  count = var.head_node_instance_id != "" && length(data.aws_instance.head_node) > 0 ? 1 : 0
  name  = element(split("/", data.aws_instance.head_node[0].iam_instance_profile), length(split("/", data.aws_instance.head_node[0].iam_instance_profile)) - 1)
}

# Attach SQS policy to head node role (required for event hooks)
resource "aws_iam_role_policy_attachment" "head_node_sqs" {
  count = length(data.aws_iam_instance_profile.head_node) > 0 ? 1 : 0

  role       = data.aws_iam_instance_profile.head_node[0].role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}



# ─────────────────────────────────────────────────────────────────────────────
# SQS QUEUE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "events" {
  name                       = "clusterra-events-${var.cluster_id}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20    # Long polling

  # CKV_AWS_27: Enable SQS encryption
  sqs_managed_sse_enabled = var.kms_key_arn == null ? true : null
  kms_master_key_id       = var.kms_key_arn

  tags = {
    Name      = "clusterra-events-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# Dead letter queue for failed messages
resource "aws_sqs_queue" "events_dlq" {
  name                      = "clusterra-events-${var.cluster_id}-dlq"
  message_retention_seconds = 604800 # 7 days

  # CKV_AWS_27: Enable SQS encryption
  sqs_managed_sse_enabled = var.kms_key_arn == null ? true : null
  kms_master_key_id       = var.kms_key_arn

  tags = {
    Name      = "clusterra-events-${var.cluster_id}-dlq"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

# Dead letter queue for Lambda failures
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "clusterra-lambda-${var.cluster_id}-dlq"
  message_retention_seconds = 604800 # 7 days

  # CKV_AWS_27: Enable SQS encryption
  sqs_managed_sse_enabled = var.kms_key_arn == null ? true : null
  kms_master_key_id       = var.kms_key_arn

  tags = {
    Name      = "clusterra-lambda-${var.cluster_id}-dlq"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
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
  name        = "clusterra-ec2-${var.cluster_id}"
  description = "Capture EC2 state changes for head node"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["pending", "running", "stopping", "stopped"]
    }
  })

  tags = {
    Name      = "clusterra-ec2-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

resource "aws_cloudwatch_event_target" "ec2_to_sqs" {
  rule = aws_cloudwatch_event_rule.ec2_state.name
  arn  = aws_sqs_queue.events.arn

  lifecycle {
    create_before_destroy = true
  }
}

# ASG events (compute node launch/terminate)
resource "aws_cloudwatch_event_rule" "asg_events" {
  name        = "clusterra-asg-${var.cluster_id}"
  description = "Capture ASG events for compute nodes"

  event_pattern = jsonencode({
    source = ["aws.autoscaling"]
    detail-type = [
      "EC2 Instance Launch Successful",
      "EC2 Instance Terminate Successful"
    ]
  })

  tags = {
    Name      = "clusterra-asg-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

resource "aws_cloudwatch_event_target" "asg_to_sqs" {
  rule = aws_cloudwatch_event_rule.asg_events.name
  arn  = aws_sqs_queue.events.arn

  lifecycle {
    create_before_destroy = true
  }
}

# Spot interruption warnings
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "clusterra-spot-${var.cluster_id}"
  description = "Capture spot interruption warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name      = "clusterra-spot-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
  }
}

resource "aws_cloudwatch_event_target" "spot_to_sqs" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.events.arn

  lifecycle {
    create_before_destroy = true
  }
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
  function_name = "clusterra-shipper-${var.cluster_id}"
  description   = "Ships cluster events to Clusterra API"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128

  role = aws_iam_role.lambda_execution.arn

  # CKV_AWS_115: Reserved concurrent execution limit
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  # CKV_AWS_272: Code signing configuration (optional)
  code_signing_config_arn = var.code_signing_config_arn

  # CKV_AWS_173: KMS encryption for environment variables
  kms_key_arn = var.kms_key_arn

  environment {
    variables = {
      CLUSTER_ID        = var.cluster_id
      TENANT_ID         = var.tenant_id
      CLUSTERRA_API_URL = var.clusterra_api_url
    }
  }

  # CKV_AWS_116: Dead Letter Queue configuration
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  # CKV_AWS_50: X-Ray tracing
  tracing_config {
    mode = "Active"
  }

  # CKV_AWS_117: VPC configuration (optional)
  dynamic "vpc_config" {
    for_each = var.vpc_config != null ? [var.vpc_config] : []
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
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

  lifecycle {
    create_before_destroy = true
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM ROLES
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_execution" {
  name = "clusterra-lambda-${var.cluster_id}"

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
    Name      = "clusterra-lambda-${var.cluster_id}"
    ManagedBy = "OpenTOFU"
    ClusterId = var.cluster_id
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
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.lambda_dlq.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# VPC permissions for Lambda (if VPC config is provided)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count      = var.vpc_config != null ? 1 : 0
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
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
