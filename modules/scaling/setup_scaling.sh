#!/bin/bash
# setup_scaling.sh - runs ON the K3s control-plane node via SSH in the customer cluster.
# Injected Env Vars: CLUSTER_NAME, CLUSTER_ENDPOINT
set -ex

sudo chmod 644 /etc/rancher/k3s/k3s.yaml || true
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
HELM=/usr/local/bin/helm
KUBECTL=/usr/local/bin/kubectl

# 1. Fetch K3s Token & AMI ID locally on the head node
echo "Waiting for K3s node-token to be generated..."
while ! sudo test -f /var/lib/rancher/k3s/server/node-token; do
  sleep 5
done

echo "Fetching K3s Token & AMI ID..."
K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
AMI_ID=$(TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600') && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/ami-id)

echo "Token: ${K3S_TOKEN:0:10}..."
echo "AMI ID: $AMI_ID"

# 2. Inject bash variables into NodeClass
export AMI_ID=$AMI_ID
export CLUSTER_ENDPOINT=$CLUSTER_ENDPOINT
export K3S_TOKEN=$K3S_TOKEN
envsubst '$AMI_ID $CLUSTER_ENDPOINT $K3S_TOKEN' < /tmp/karpenter-nodeclass.yaml > /tmp/karpenter-nodeclass.yaml.applied

# 3. Install Karpenter
echo "Installing Karpenter..."
if ! $HELM status karpenter -n karpenter > /dev/null 2>&1; then
  $HELM install karpenter oci://public.ecr.aws/karpenter/karpenter --version 0.37.0 \
    --namespace karpenter --create-namespace \
    --set settings.clusterName=${CLUSTER_NAME} \
    --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
    --set replicas=1 \
    --set controller.resources.requests.cpu=200m \
    --set controller.resources.limits.cpu=1000m \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.memory=1Gi \
    --wait
else
  $HELM upgrade karpenter oci://public.ecr.aws/karpenter/karpenter --version 0.37.0 \
    --namespace karpenter \
    --set settings.clusterName=${CLUSTER_NAME} \
    --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
    --set replicas=1 \
    --set controller.resources.requests.cpu=200m \
    --set controller.resources.limits.cpu=1000m \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.memory=1Gi \
    --wait
fi

# 4. Apply Karpenter manifests
echo "Applying Karpenter manifests..."
$KUBECTL create namespace slurm-operator --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL apply -f /tmp/karpenter-nodeclass.yaml.applied
$KUBECTL apply -f /tmp/karpenter-nodepool.yaml

# 5. Install Slinky slurm-operator (operator-only, no local slurmctld)
echo "Installing Slinky slurm-operator from OCI..."
CHART_VERSION="1.0.0"

# Install CRDs first (managed separately for upgrade safety)
# OCI charts must be installed directly via the oci:// URL
if ! $HELM status slurm-operator-crds -n slurm-operator > /dev/null 2>&1; then
  $HELM install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
    --namespace slurm-operator --create-namespace \
    --version $CHART_VERSION
else
  $HELM upgrade slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
    --namespace slurm-operator \
    --version $CHART_VERSION
fi

# Install / upgrade the operator itself
if ! $HELM status slurm-operator -n slurm-operator > /dev/null 2>&1; then
  $HELM install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
    --namespace slurm-operator \
    --version $CHART_VERSION \
    --values /tmp/slurm-operator-values.yaml \
    --wait
else
  $HELM upgrade slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
    --namespace slurm-operator \
    --version $CHART_VERSION \
    --values /tmp/slurm-operator-values.yaml \
    --wait
fi

$KUBECTL wait --for=condition=available --timeout=300s deployment/slurm-operator -n slurm-operator

# 6. Apply Controller CR (points the operator at the external central slurmctld)
echo "Applying Slurm Controller CR..."
$KUBECTL apply -f /tmp/slurm-controller-cr.yaml

# 7. Apply NodeSet CR (defines the worker pool)
echo "Applying Slurm NodeSet CR..."
$KUBECTL apply -f /tmp/slurm-nodeset-cr.yaml

# 8. Install KEDA and apply Autoscaling configuration
echo "Installing KEDA for NodeSet Autoscaling..."
$HELM repo add kedacore https://kedacore.github.io/charts
$HELM repo update

if ! $HELM status keda -n keda > /dev/null 2>&1; then
  $HELM install keda kedacore/keda \
    --namespace keda --create-namespace \
    --wait
fi

# Apply the ScaledObject
echo "Applying KEDA ScaledObject..."
$KUBECTL apply -f /tmp/keda-scaledobject.yaml

echo "Scaling setup complete!"
