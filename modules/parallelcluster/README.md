# Clusterra ParallelCluster Module

Creates AWS ParallelCluster prerequisites and generates the cluster configuration.

## What It Creates

- Slurm JWT secret in Secrets Manager (for Clusterra authentication)
- EFS file system (demo) or FSx Lustre (prod)
- Generated `cluster-config.yaml` for `pcluster` CLI

## Usage

```hcl
module "cluster" {
  source = "./modules/parallelcluster"
  
  cluster_name            = "my-cluster"
  region                  = "ap-south-1"
  vpc_id                  = "vpc-xxx"
  subnet_id               = "subnet-xxx"
  ssh_key_name            = "my-key"
  customer_id             = "cust_abc123"
  
  # Optional
  head_node_instance_type = "t3.small"
  compute_instance_type   = "c5.large"
  max_count               = 10
  shared_storage_type     = "efs"  # or "fsx_lustre"
}
```

## After `tofu apply`

Run the generated pcluster command:

```bash
pcluster create-cluster \
  --cluster-name my-cluster \
  --cluster-configuration ./modules/parallelcluster/generated/my-cluster-config.yaml \
  --region ap-south-1
```

## Outputs

| Output | Description |
|--------|-------------|
| `slurm_jwt_secret_arn` | Provide to Clusterra for authentication |
| `deploy_command` | Ready-to-run pcluster command |
| `head_node_ip_command` | Command to get head node IP after creation |
