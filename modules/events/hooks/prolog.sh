#!/bin/bash
# /opt/clusterra/prolog.sh
# 
# Slurm Prolog - runs on COMPUTE node when job's first step starts
# Sends job.started event to SQS asynchronously
#
# This script MUST exit 0 to avoid blocking job execution.

# Run Python hook in background (async, non-blocking)
(/opt/clusterra/clusterra-hook.py job.started &)

# Chain to customer's prolog if exists
if [ -x /opt/slurm/etc/customer_prolog.sh ]; then
    exec /opt/slurm/etc/customer_prolog.sh
fi

exit 0
