#!/bin/bash
# Setup slurmrestd with JWT authentication for Clusterra integration
# This script runs on the head node after ParallelCluster configuration
# Compatible with Amazon Linux 2023

set -e

# Arguments
# SSM Document exports SecretArn as environment variable via {{ SecretArn }}
# Fall back to $1 for manual invocation/testing
JWT_SECRET_ARN="${SecretArn:-${1:-}}"

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

# 1. Retrieve JWT key from Secrets Manager (Terraform is the source of truth)
if [ -z "$JWT_SECRET_ARN" ]; then
    echo "ERROR: JWT_SECRET_ARN is required. Terraform should have created the secret."
    exit 1
fi

echo "Retrieving JWT key from Secrets Manager..."
# Retry logic for IAM propagation delays
MAX_RETRIES=5
RETRY_DELAY=10

for i in $(seq 1 $MAX_RETRIES); do
    JWT_KEY=$(aws secretsmanager get-secret-value --secret-id "$JWT_SECRET_ARN" --query 'SecretString' --output text 2>/dev/null)

    if [ -n "$JWT_KEY" ] && [ "$JWT_KEY" != "null" ]; then
        echo "Successfully retrieved JWT key from Secrets Manager"
        break
    fi

    if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: Failed to retrieve JWT key from Secrets Manager after $MAX_RETRIES attempts."
        echo "Ensure Terraform has created the secret and IAM permissions are correct."
        exit 1
    fi

    echo "Waiting for secret to be available (attempt $i/$MAX_RETRIES)..."
    sleep $RETRY_DELAY
done

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

# 4b. Update slurmdbd.conf with JWT authentication (Fixes 502 TRES error)
SLURMDBD_CONF="/opt/slurm/etc/slurmdbd.conf"
if ! grep -q "AuthAltTypes=auth/jwt" "$SLURMDBD_CONF"; then
    echo "Adding JWT authentication to slurmdbd.conf..."
    sudo tee -a "$SLURMDBD_CONF" << EOF

# JWT Authentication (added by Clusterra)
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=$JWT_KEY_PATH
EOF

    echo "Restarting slurmdbd..."
    sudo systemctl restart slurmdbd || true
    sleep 3
fi

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

# 7. Ensure both slurm (slurmctld) and slurmrestd can read JWT key
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
