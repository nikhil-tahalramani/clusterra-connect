#!/bin/bash
# Setup slurmrestd with JWT authentication for Clusterra integration
# This script runs on the head node after ParallelCluster configuration
# Compatible with Amazon Linux 2023

set -e

# Arguments
JWT_SECRET_ARN="${1:-}"

# Paths (ParallelCluster standard locations)
SLURM_CONF="/opt/slurm/etc/slurm.conf"
JWT_KEY_PATH="/opt/slurm/etc/jwt_hs256.key"
SLURMRESTD_PORT=6830

echo "=== Clusterra: Configuring slurmrestd for JWT authentication ==="

# Source Slurm environment
if [ -f /etc/profile.d/slurm.sh ]; then
    source /etc/profile.d/slurm.sh
fi

# Install http-parser library (required by slurmrestd on AL2023)
echo "Installing slurmrestd dependencies..."
# Remove any existing incompatible version
rpm -e http-parser --nodeps 2>/dev/null || true

# Install Fedora 34 version which provides libhttp_parser.so.2.9.4
echo "Installing http-parser 2.9.4 from Fedora archives..."
rpm -ivh https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/34/Everything/x86_64/os/Packages/h/http-parser-2.9.4-4.fc34.x86_64.rpm || echo "Warning: Failed to install http-parser"

# Symlink hack: slurmrestd explicitly looks for .so.2.9
if [ -f /usr/lib64/libhttp_parser.so.2.9.4 ] && [ ! -f /usr/lib64/libhttp_parser.so.2.9 ]; then
    echo "Creating symlink for libhttp_parser.so.2.9..."
    ln -s /usr/lib64/libhttp_parser.so.2.9.4 /usr/lib64/libhttp_parser.so.2.9
fi

# 1. Generate or retrieve JWT key
if [ -n "$JWT_SECRET_ARN" ]; then
    echo "Retrieving JWT key from Secrets Manager..."
    # Check if secret exists and has a value
    SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$JWT_SECRET_ARN" --query 'SecretString' --output text 2>/dev/null || echo "")
    
    if [ -z "$SECRET_VALUE" ] || [ "$SECRET_VALUE" == "PLACEHOLDER" ]; then
        echo "Generating new JWT key..."
        JWT_KEY=$(openssl rand -hex 32)
        aws secretsmanager put-secret-value --secret-id "$JWT_SECRET_ARN" --secret-string "$JWT_KEY"
    else
        JWT_KEY="$SECRET_VALUE"
    fi
else
    echo "No secret ARN provided, generating local JWT key..."
    JWT_KEY=$(openssl rand -hex 32)
fi

# 2. Write JWT key to file
printf "%s" "$JWT_KEY" | sudo tee "$JWT_KEY_PATH" > /dev/null
sudo chmod 600 "$JWT_KEY_PATH"
sudo chown slurm:slurm "$JWT_KEY_PATH"
echo "JWT key written to $JWT_KEY_PATH"

# 3. Update slurm.conf with JWT authentication
if ! grep -q "AuthAltTypes=auth/jwt" "$SLURM_CONF"; then
    echo "Adding JWT authentication to slurm.conf..."
    sudo tee -a "$SLURM_CONF" << EOF

# JWT Authentication for slurmrestd (added by Clusterra)
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=$JWT_KEY_PATH
EOF
fi

# 4. Restart slurmctld to pick up JWT config
echo "Restarting slurmctld..."
sudo systemctl restart slurmctld || true
sleep 3

# 5. Create systemd service
echo "Creating slurmrestd systemd service..."

# Detect local IP to avoid IPv6 binding issues with 0.0.0.0
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "Detected local IP: $LOCAL_IP"

# Force kill any lingering manual instances to free up port
sudo pkill -9 slurmrestd || true

cat << EOF | sudo tee /etc/systemd/system/slurmrestd.service
[Unit]
Description=Slurm REST API (Clusterra)
After=slurmctld.service munge.service network-online.target
Wants=slurmctld.service

[Service]
Type=simple
User=slurmrestd
Group=slurmrestd
Environment=SLURM_CONF=$SLURM_CONF
# Environment=SLURM_JWT=$JWT_KEY_PATH # Replaced by daemon mode for header pass-through
Environment=SLURM_JWT=daemon
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt -s openapi/slurmctld 0.0.0.0:$SLURMRESTD_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. Create slurmrestd user if not exists
if ! id slurmrestd &>/dev/null; then
    echo "Creating slurmrestd user..."
    sudo useradd -r -s /bin/false slurmrestd
fi

# 6b. Create Clusterra runner user for job execution
# This user is used by all jobs submitted via Clusterra
# Extract cluster_id from hostname (format: {cluster_name}-HeadNode or similar)
CLUSTER_ID="${CLUSTER_ID:-$(hostname | grep -oE 'clus[a-z0-9]+' || echo 'default')}"
RUNNER_USER="linux_user_${CLUSTER_ID}"

if ! id "$RUNNER_USER" &>/dev/null; then
    echo "Creating Clusterra runner user: $RUNNER_USER"
    sudo useradd -m -s /bin/bash -d "/home/${RUNNER_USER}" "$RUNNER_USER"
fi

# 6c. Create default Slurm account for Clusterra users
# This provides a shared accounting namespace for all tenant users
echo "Creating default Slurm account..."
sacctmgr -i add account clusterra_default Description="Clusterra default account" 2>/dev/null || true

# 7. Give slurmrestd user access to JWT key
sudo chown slurm:slurmrestd "$JWT_KEY_PATH"
sudo chmod 640 "$JWT_KEY_PATH"

# 8. Enable and start service
echo "Enabling and starting slurmrestd..."
sudo systemctl daemon-reload
# Disable socket if it was enabled
sudo systemctl disable --now slurmrestd.socket 2>/dev/null || true
# Enable service
sudo systemctl enable slurmrestd.service
sudo systemctl restart slurmrestd.service

# 9. Verify
sleep 3
if sudo systemctl is-active slurmrestd; then
    echo "=== slurmrestd is running ==="
    ss -tlnp | grep $SLURMRESTD_PORT || true
else
    echo "=== slurmrestd failed to start, checking logs ==="
    sudo journalctl -u slurmrestd -n 20 --no-pager || true
fi

echo "=== Clusterra: slurmrestd setup complete ==="
