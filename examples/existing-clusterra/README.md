# Existing Clusterra Cluster Example

Re-connect an existing cluster that was previously deployed with clusterra-connect.
This only deploys connectivity and events modules (no ParallelCluster config).

## Usage

```bash
# 1. Copy example variables
cp terraform.tfvars.example terraform.tfvars

# 2. Edit with your values (including cluster_id and tenant_id)
vim terraform.tfvars

# 3. Apply
tofu init
tofu apply

# 4. Install/update hooks on head node if needed
pcluster ssh -n my-cluster
sudo /opt/clusterra/install-hooks.sh <SQS_URL_FROM_OUTPUT>
```

## What Gets Created

| Resource | Description |
|----------|-------------|
| SQS Queue | Events from hooks and CloudWatch |
| Lambda | Ships events to Clusterra API |
| CloudWatch Rules | EC2/ASG event capture |

Note: Connectivity module (NLB, PrivateLink, IAM) assumed to already exist.
