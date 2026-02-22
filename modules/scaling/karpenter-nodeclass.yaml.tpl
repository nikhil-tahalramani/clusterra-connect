apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: Custom
  amiSelectorTerms:
    - id: "$${AMI_ID}" # Injected by bash string replacement in the setup script
  role: "${karpenter_role}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${cluster_name}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${cluster_name}"
  tags:
    Name: "${cluster_name}-worker"
  userData: |
    #!/bin/bash
    curl -sfL https://get.k3s.io | K3S_URL=$${CLUSTER_ENDPOINT} K3S_TOKEN=$${K3S_TOKEN} sh -
