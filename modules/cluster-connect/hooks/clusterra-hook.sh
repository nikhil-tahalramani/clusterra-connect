#!/bin/bash
# clusterra-hook.sh - Fire-and-forget event delivery to Clusterra API
#
# This script sends Slurm job events directly to Clusterra API via HTTPS.
# Runs in background (&) to avoid blocking the Slurm scheduler.
#
# Usage (called by Slurm prolog/epilog):
#   clusterra-hook.sh <event_type>
#
# Event types: job.started, job.completed, job.failed, job.cancelled
#

set -o pipefail

# Load configuration
source /etc/clusterra/hooks.env 2>/dev/null || true

EVENT_TYPE="${1:-unknown}"

# Skip if not configured
if [[ -z "${CLUSTER_ID:-}" || -z "${TENANT_ID:-}" ]]; then
    exit 0
fi

# Build JSON event payload for PutEvents
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Construct JSON entries for aws events put-events
# escaping quotes for bash string
ENTRIES=$(cat <<EOF
[
  {
    "Time": "$TIMESTAMP",
    "Source": "clusterra.slurm",
    "Resources": [],
    "DetailType": "$EVENT_TYPE",
    "Detail": "{\"job_id\": \"${SLURM_JOB_ID:-}\", \"user\": \"${SLURM_JOB_USER:-}\", \"partition\": \"${SLURM_JOB_PARTITION:-}\", \"node\": \"${SLURMD_NODENAME:-}\", \"exit_code\": \"${SLURM_JOB_EXIT_CODE:-}\", \"state\": \"${SLURM_JOB_STATE:-}\", \"nodes\": \"${SLURM_JOB_NODELIST:-}\"}"
  }
]
EOF
)

# Fire-and-forget: aws runs in background
# Requires 'events:PutEvents' permission on Head Node Role
(aws events put-events --entries "$ENTRIES" --region "${AWS_REGION:-$(aws configure get region)}" >/dev/null 2>&1) &

# Exit immediately - don't wait
exit 0
