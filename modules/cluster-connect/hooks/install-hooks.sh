#!/bin/bash
# install-hooks.sh
#
# Install Clusterra hooks on ParallelCluster head node
# Run this on the head node after cluster creation
#
# Usage: install-hooks.sh <cluster_id> <tenant_id> <event_bus_arn> [api_endpoint]
#
# v5: Uses EventBridge cross-account PutEvents for event delivery

set -e

CLUSTER_ID="${1:-}"
TENANT_ID="${2:-}"
EVENT_BUS_ARN="${3:-}"
API_ENDPOINT="${4:-api.clusterra.cloud}"

if [ -z "$CLUSTER_ID" ] || [ -z "$TENANT_ID" ] || [ -z "$EVENT_BUS_ARN" ]; then
    echo "Usage: install-hooks.sh <cluster_id> <tenant_id> <event_bus_arn> [api_endpoint]"
    echo "  cluster_id:     Your Clusterra cluster ID (e.g., clusa1b2)"
    echo "  tenant_id:      Your Clusterra tenant ID"
    echo "  event_bus_arn:   Clusterra EventBridge bus ARN (cross-account)"
    echo "  api_endpoint:    Clusterra API endpoint (default: api.clusterra.cloud)"
    exit 1
fi

CLUSTERRA_DIR="/opt/clusterra"
SLURM_CONF="/opt/slurm/etc/slurm.conf"

echo "=== Installing Clusterra Hooks (v5 - EventBridge) ==="

# 0. Allow 'slurm' user (UID 401) to access IMDS (Required for IAM role assumption)
# ParallelCluster blocks non-root/pcluster-admin users by default.
echo "Configuring IMDS access for slurm user..."
if ! sudo iptables -C PARALLELCLUSTER_IMDS -d 169.254.169.254 -m owner --uid-owner 401 -j ACCEPT 2>/dev/null; then
    sudo iptables -I PARALLELCLUSTER_IMDS 1 -d 169.254.169.254 -m owner --uid-owner 401 -j ACCEPT
    echo " - Added iptables rule for UID 401"
else
    echo " - iptables rule already exists"
fi
# Note: Ideally this should be persisted via ParallelCluster config or netfilter-persistent,
# but for now we apply it at runtime. It may be lost on reboot if not persisted.

# 1. Create directory
sudo mkdir -p "$CLUSTERRA_DIR"

# 2. Copy hook scripts (assuming they're in same dir as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/clusterra-hook.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/prolog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/epilog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/slurmctld_prolog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/slurmctld_epilog.sh" "$CLUSTERRA_DIR/"

# 3. Make executable
sudo chmod +x "$CLUSTERRA_DIR"/*

# 4. Create environment file
sudo mkdir -p /etc/clusterra
sudo tee /etc/clusterra/hooks.env > /dev/null <<EOF
# Clusterra Hook Configuration (v5 - EventBridge)
CLUSTER_ID=$CLUSTER_ID
TENANT_ID=$TENANT_ID
CLUSTERRA_EVENT_BUS_ARN=$EVENT_BUS_ARN
CLUSTERRA_API_ENDPOINT=$API_ENDPOINT
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "ap-south-1")
EOF
sudo chmod 644 /etc/clusterra/hooks.env

# 5. Wrapper that sources env
sudo tee "$CLUSTERRA_DIR/run-hook.sh" > /dev/null <<'WRAPPER'
#!/bin/bash
source /etc/clusterra/hooks.env
export CLUSTER_ID TENANT_ID CLUSTERRA_API_ENDPOINT
exec "$@"
WRAPPER
sudo chmod +x "$CLUSTERRA_DIR/run-hook.sh"

# 6. Prefix-and-wrap: Backup existing customer hooks before installing wrappers
SLURM_ETC="/opt/slurm/etc"

echo "Setting up hook wrappers..."

# Backup existing prolog.sh if it exists and isn't already ours
if [ -f "$SLURM_ETC/prolog.sh" ] && ! grep -q "clusterra" "$SLURM_ETC/prolog.sh"; then
    echo "Backing up existing prolog.sh to prolog.sh.customer"
    sudo mv "$SLURM_ETC/prolog.sh" "$SLURM_ETC/prolog.sh.customer"
fi

# Backup existing epilog.sh if it exists and isn't already ours
if [ -f "$SLURM_ETC/epilog.sh" ] && ! grep -q "clusterra" "$SLURM_ETC/epilog.sh"; then
    echo "Backing up existing epilog.sh to epilog.sh.customer"
    sudo mv "$SLURM_ETC/epilog.sh" "$SLURM_ETC/epilog.sh.customer"
fi

# Install Clusterra wrappers at standard Slurm locations
sudo cp "$CLUSTERRA_DIR/prolog.sh" "$SLURM_ETC/prolog.sh"
sudo cp "$CLUSTERRA_DIR/epilog.sh" "$SLURM_ETC/epilog.sh"
sudo chmod +x "$SLURM_ETC/prolog.sh" "$SLURM_ETC/epilog.sh"

# 7. Update slurm.conf with slurmctld hooks (only if not already configured)
if ! grep -q "PrologSlurmctld=" "$SLURM_CONF"; then
    echo "Updating slurm.conf with Clusterra slurmctld hooks..."
    sudo tee -a "$SLURM_CONF" > /dev/null <<EOF

# Clusterra Hooks (added by install-hooks.sh v5)
PrologSlurmctld=$CLUSTERRA_DIR/slurmctld_prolog.sh
EpilogSlurmctld=$CLUSTERRA_DIR/slurmctld_epilog.sh
# Node-level hooks are at standard locations: /opt/slurm/etc/prolog.sh, epilog.sh
EOF
else
    echo "Slurm hooks already configured"
fi

# 8. Restart slurmctld
echo "Restarting slurmctld..."
sudo systemctl restart slurmctld || true

# 9. Test API access
echo "Testing Clusterra API access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Cluster-ID: $CLUSTER_ID" \
    -d "{\"cluster_id\":\"$CLUSTER_ID\",\"tenant_id\":\"$TENANT_ID\",\"source\":\"clusterra.slurm\",\"detail-type\":\"test.install\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"detail\":{\"event\":\"hooks_installed\"}}" \
    "https://${API_ENDPOINT}/v1/internal/events" 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo " - API test successful (HTTP 200)"
elif [ "$HTTP_CODE" = "404" ]; then
    echo " - API responded with 404 (cluster not yet registered - this is normal during initial setup)"
else
    echo " - Warning: API test returned HTTP $HTTP_CODE"
fi

echo ""
echo "=== Clusterra Hooks Installed (v5 - EventBridge) ==="
echo "Cluster ID: $CLUSTER_ID"
echo "Tenant ID: $TENANT_ID"
echo "Event Bus: $EVENT_BUS_ARN"
echo "API Endpoint: $API_ENDPOINT"
