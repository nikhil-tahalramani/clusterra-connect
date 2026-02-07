#!/bin/bash
# /opt/slurm/etc/prolog.sh (installed by Clusterra)
#
# Slurm Prolog - runs on COMPUTE node when job's first step starts
# Sends job.started event to Clusterra API asynchronously (v2 - curl)
#
# This script MUST exit 0 to avoid blocking job execution.

# Run Clusterra hook in background (async, non-blocking)
if [ -f /etc/clusterra/hooks.env ]; then
    source /etc/clusterra/hooks.env
    export CLUSTERRA_API_URL CLUSTER_ID TENANT_ID
fi
(/opt/clusterra/clusterra-hook.sh job.started &)

# Chain to customer's original prolog if it was backed up during install
if [ -x /opt/slurm/etc/prolog.sh.customer ]; then
    exec /opt/slurm/etc/prolog.sh.customer
fi

exit 0
