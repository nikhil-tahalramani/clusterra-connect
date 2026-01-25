#!/bin/bash
# /opt/clusterra/slurmctld_epilog.sh
#
# Slurm Controller Epilog - runs on HEAD node when job terminates
# Sends final job event (completed/failed/cancelled/timeout) to SQS
#
# This script MUST exit 0 to avoid issues.

# Determine event type from job state and exit code
EVENT="job.completed"
EXIT_CODE="${SLURM_JOB_EXIT_CODE:-0}"
JOB_STATE="${SLURM_JOB_STATE:-COMPLETED}"

case "$JOB_STATE" in
    CANCELLED*)
        EVENT="job.cancelled"
        ;;
    TIMEOUT*)
        EVENT="job.timeout"
        ;;
    FAILED*|NODE_FAIL*|PREEMPTED*)
        EVENT="job.failed"
        ;;
    COMPLETED*)
        if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "0:0" ]; then
            EVENT="job.failed"
        else
            EVENT="job.completed"
        fi
        ;;
    *)
        # Default: check exit code
        if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "0:0" ]; then
            EVENT="job.failed"
        fi
        ;;
esac

# Run Python hook in background (async, non-blocking)
(/opt/clusterra/clusterra-hook.py "$EVENT" &)

# Chain to customer's slurmctld epilog if exists
if [ -x /opt/slurm/etc/customer_slurmctld_epilog.sh ]; then
    exec /opt/slurm/etc/customer_slurmctld_epilog.sh
fi

exit 0
