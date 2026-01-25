# New Cluster Example

Deploy a brand new ParallelCluster with full Clusterra integration.

## Usage

```bash
# 1. Copy example variables
cp terraform.tfvars.example terraform.tfvars

# 2. Edit with your values
vim terraform.tfvars

# 3. Initialize and apply (Phase 1: connectivity only)
tofu init
tofu apply

# 4. Create the cluster with pcluster
pcluster create-cluster -n my-cluster -c ./generated/my-cluster-config.yaml

# 5. Register in Clusterra console using outputted values

# 6. After registration, update tfvars with cluster_id and tenant_id
# Then re-apply to deploy events module
tofu apply

# 7. Install hooks on head node
pcluster ssh -n my-cluster
sudo /opt/clusterra/install-hooks.sh <SQS_URL_FROM_OUTPUT>
```

## What Gets Created

| Resource | Description |
|----------|-------------|
| ParallelCluster config | YAML configuration for pcluster |
| NLB | Routes traffic to slurmrestd |
| VPC Endpoint Service | Exposes NLB via PrivateLink |
| IAM Role | Cross-account access for Clusterra |
| SQS Queue | Events from hooks and CloudWatch |
| Lambda | Ships events to Clusterra API |
| CloudWatch Rules | EC2/ASG event capture |
