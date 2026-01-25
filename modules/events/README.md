# Clusterra Events Module

Deploys event shipping infrastructure for Clusterra integration.

## Resources Created

| Resource | Description |
|----------|-------------|
| **SQS Queue** | Receives events from Slurm hooks and CloudWatch |
| **SQS DLQ** | Dead letter queue for failed messages |
| **Lambda Function** | Processes SQS messages, ships to Clusterra API |
| **CloudWatch Event Rules** | Captures EC2/ASG state changes |
| **IAM Roles** | Lambda execution and Slurm hook permissions |

## Inputs

| Variable | Description | Required |
|----------|-------------|----------|
| `cluster_name` | ParallelCluster name | Yes |
| `cluster_id` | Clusterra cluster ID (clus_xxx) | Yes |
| `tenant_id` | Clusterra tenant ID (ten_xxx) | Yes |
| `region` | AWS region | Yes |
| `clusterra_api_url` | Clusterra API URL | No (default: https://api.clusterra.cloud) |

## Outputs

| Output | Description |
|--------|-------------|
| `sqs_queue_url` | SQS queue URL for Slurm hooks |
| `slurm_sqs_policy_arn` | IAM policy to attach to cluster instance role |
| `lambda_function_name` | Event shipper Lambda name |
| `install_hooks_command` | Command to run on head node |

## Usage

```hcl
module "events" {
  source = "./modules/events"

  cluster_name      = "my-hpc-cluster"
  cluster_id        = "clus_abc123"
  tenant_id         = "ten_xyz789"
  region            = "ap-south-1"
}
```

After apply, install hooks on head node:

```bash
pcluster ssh -n my-cluster
sudo /opt/clusterra/install-hooks.sh <SQS_URL>
```

## Event Flow

```
Slurm hooks → SQS → Lambda → Clusterra API
CloudWatch  → SQS → Lambda → Clusterra API
```
