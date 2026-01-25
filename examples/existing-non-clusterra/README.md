# Existing Non-Clusterra Cluster Example

Connect an existing ParallelCluster that was NOT deployed via Clusterra.
Deploys full connectivity + events infrastructure.

## Prerequisites

1. Existing ParallelCluster with slurmrestd configured
2. AWS Secrets Manager secret containing JWT key for slurmrestd

## Usage

```bash
# 1. Copy example variables
cp terraform.tfvars.example terraform.tfvars

# 2. Edit with your values
vim terraform.tfvars

# 3. Apply Phase 1 (connectivity only)
tofu init
tofu apply

# 4. Register in Clusterra console using outputted values

# 5. Add cluster_id and tenant_id to tfvars, re-apply
tofu apply

# 6. Install hooks on head node
pcluster ssh -n my-cluster
sudo /opt/clusterra/install-hooks.sh <SQS_URL_FROM_OUTPUT>
```

## What Gets Created

| Resource | Description |
|----------|-------------|
| NLB | Routes traffic to slurmrestd |
| VPC Endpoint Service | Exposes NLB via PrivateLink |
| IAM Role | Cross-account access for Clusterra |
| SQS Queue | Events from hooks and CloudWatch |
| Lambda | Ships events to Clusterra API |
| CloudWatch Rules | EC2/ASG event capture |
