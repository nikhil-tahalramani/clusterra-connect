terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# TODO: Implement PrivateLink + NLB + IAM logic here
# 1. Create NLB pointing to Head Node (requires identifying Head Node IP)
# 2. Create VPC Endpoint Service attached to NLB
# 3. Create IAM Role for Clusterra to assume (modules/connect or root?)
# 4. Call cluster/connect/{tenant_id} API?
