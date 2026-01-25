# Clusterra Events Module
#
# Creates SQS queue, CloudWatch Event Rules, and Event Shipper Lambda
# for shipping cluster events to Clusterra API.

output "sqs_queue_url" {
  description = "SQS queue URL for Slurm hooks"
  value       = aws_sqs_queue.events.url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN"
  value       = aws_sqs_queue.events.arn
}

output "slurm_sqs_policy_arn" {
  description = "IAM policy ARN to attach to ParallelCluster instance role"
  value       = aws_iam_policy.slurm_sqs_send.arn
}

output "lambda_function_name" {
  description = "Event shipper Lambda function name"
  value       = aws_lambda_function.event_shipper.function_name
}

output "install_hooks_command" {
  description = "Command to install Clusterra hooks on head node"
  value       = "sudo /opt/clusterra/install-hooks.sh ${aws_sqs_queue.events.url}"
}
