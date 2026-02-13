#!/bin/bash
# clusterra-hook.sh - Fire-and-forget event delivery to Clusterra EventBridge
#
# Sends Slurm job events to the Clusterra cross-account EventBridge bus.
# Runs in background (&) to avoid blocking the Slurm scheduler.
#
# Usage (called by Slurm prolog/epilog):
#   clusterra-hook.sh <event_type>
#
# Event types: job.allocated, job.running, job.completed, job.failed, job.cancelled
#

set -o pipefail

# Load configuration
source /etc/clusterra/hooks.env 2>/dev/null || true

EVENT_TYPE="${1:-unknown}"

# Skip if not configured
if [[ -z "${CLUSTER_ID:-}" || -z "${TENANT_ID:-}" || -z "${CLUSTERRA_EVENT_BUS_ARN:-}" ]]; then
    exit 0
fi

# Build JSON event payload for PutEvents
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Construct JSON entries for aws events put-events
# EventBusName targets the cross-account Clusterra event bus
# Detail includes tenant_id and cluster_id for downstream routing
ENTRIES=$(cat <<EOF
[
  {
    "Time": "$TIMESTAMP",
    "Source": "clusterra.slurm",
    "Resources": [],
    "DetailType": "$EVENT_TYPE",
    "EventBusName": "$CLUSTERRA_EVENT_BUS_ARN",
    "Detail": "{\"job_id\": \"${SLURM_JOB_ID:-}\", \"user\": \"${SLURM_JOB_USER:-}\", \"partition\": \"${SLURM_JOB_PARTITION:-}\", \"node\": \"${SLURMD_NODENAME:-}\", \"exit_code\": \"${SLURM_JOB_EXIT_CODE:-}\", \"state\": \"${SLURM_JOB_STATE:-}\", \"nodes\": \"${SLURM_JOB_NODELIST:-}\", \"tenant_id\": \"${TENANT_ID}\", \"cluster_id\": \"${CLUSTER_ID}\"}"
  }
]
EOF
)

# Send event synchronously - this script is already backgrounded by the caller
aws events put-events --entries "$ENTRIES" --region "${AWS_REGION:-ap-south-1}" >/dev/null 2>&1

exit 0
