#!/bin/bash
# install-hooks.sh
#
# Install Clusterra hooks on ParallelCluster head node
# Run this on the head node after cluster creation
#
# Usage: install-hooks.sh <sqs_queue_url>

set -e

SQS_URL="${1:-}"

if [ -z "$SQS_URL" ]; then
    echo "Usage: install-hooks.sh <sqs_queue_url>"
    exit 1
fi

CLUSTERRA_DIR="/opt/clusterra"
SLURM_CONF="/opt/slurm/etc/slurm.conf"

echo "=== Installing Clusterra Hooks ==="

# 1. Create directory
sudo mkdir -p "$CLUSTERRA_DIR"

# 2. Copy hook scripts (assuming they're in same dir as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/clusterra-hook.py" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/prolog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/epilog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/slurmctld_prolog.sh" "$CLUSTERRA_DIR/"
sudo cp "$SCRIPT_DIR/slurmctld_epilog.sh" "$CLUSTERRA_DIR/"

# 3. Make executable
sudo chmod +x "$CLUSTERRA_DIR"/*

# 4. Create environment file
sudo tee /etc/clusterra/hooks.env > /dev/null <<EOF
CLUSTERRA_SQS_URL=$SQS_URL
EOF
sudo chmod 600 /etc/clusterra/hooks.env

# 5. Wrapper that sources env
sudo tee "$CLUSTERRA_DIR/run-hook.sh" > /dev/null <<'WRAPPER'
#!/bin/bash
source /etc/clusterra/hooks.env
export CLUSTERRA_SQS_URL
exec "$@"
WRAPPER
sudo chmod +x "$CLUSTERRA_DIR/run-hook.sh"

# 6. Update slurm.conf
if ! grep -q "PrologSlurmctld=" "$SLURM_CONF"; then
    echo "Updating slurm.conf with Clusterra hooks..."
    sudo tee -a "$SLURM_CONF" > /dev/null <<EOF

# Clusterra Hooks (added by install-hooks.sh)
PrologSlurmctld=$CLUSTERRA_DIR/run-hook.sh $CLUSTERRA_DIR/slurmctld_prolog.sh
EpilogSlurmctld=$CLUSTERRA_DIR/run-hook.sh $CLUSTERRA_DIR/slurmctld_epilog.sh
Prolog=$CLUSTERRA_DIR/run-hook.sh $CLUSTERRA_DIR/prolog.sh
Epilog=$CLUSTERRA_DIR/run-hook.sh $CLUSTERRA_DIR/epilog.sh
EOF
else
    echo "Slurm hooks already configured"
fi

# 7. Restart slurmctld
echo "Restarting slurmctld..."
sudo systemctl restart slurmctld || true

# 8. Test SQS access
echo "Testing SQS access..."
aws sqs send-message \
    --queue-url "$SQS_URL" \
    --message-body '{"event":"test.install","ts":"'$(date -Iseconds)'"}' \
    && echo "SQS test successful" \
    || echo "Warning: SQS test failed - check IAM permissions"

echo "=== Clusterra Hooks Installed ==="
echo "SQS Queue: $SQS_URL"
