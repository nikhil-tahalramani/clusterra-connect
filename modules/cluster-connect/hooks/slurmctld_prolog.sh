#!/bin/bash
# /opt/clusterra/slurmctld_prolog.sh
#
# Slurm Controller Prolog - runs on HEAD node when job is allocated
# Sends job.allocated event via curl (fire-and-forget)
#
# This script MUST exit 0 to avoid blocking job scheduling.

# Source configuration and run hook in background (async, non-blocking)
if [ -f /etc/clusterra/hooks.env ]; then
    source /etc/clusterra/hooks.env
    export CLUSTER_ID TENANT_ID CLUSTERRA_API_ENDPOINT
fi
(/opt/clusterra/clusterra-hook.sh job.allocated &)

# Chain to customer's slurmctld prolog if exists
if [ -x /opt/slurm/etc/customer_slurmctld_prolog.sh ]; then
    exec /opt/slurm/etc/customer_slurmctld_prolog.sh
fi

exit 0
