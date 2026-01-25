#!/bin/bash
# /opt/clusterra/slurmctld_prolog.sh
#
# Slurm Controller Prolog - runs on HEAD node when job is allocated
# Sends job.allocated event to SQS asynchronously
#
# This script MUST exit 0 to avoid blocking job scheduling.

# Run Python hook in background (async, non-blocking)
(/opt/clusterra/clusterra-hook.py job.allocated &)

# Chain to customer's slurmctld prolog if exists
if [ -x /opt/slurm/etc/customer_slurmctld_prolog.sh ]; then
    exec /opt/slurm/etc/customer_slurmctld_prolog.sh
fi

exit 0
