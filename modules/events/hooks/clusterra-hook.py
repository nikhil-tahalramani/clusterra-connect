#!/usr/bin/env python3
"""
Clusterra Hook - Sends events to SQS

Usage:
    clusterra-hook.py <event_type> [additional_data_json]

Examples:
    clusterra-hook.py job.started
    clusterra-hook.py job.completed '{"exit_code": 0}'
    
Environment variables from Slurm:
    SLURM_JOB_ID, SLURM_JOB_USER, SLURM_JOB_PARTITION, etc.
"""

import boto3
import json
import os
import sys
from datetime import datetime

# SQS queue URL set by Clusterra installation
QUEUE_URL = os.environ.get("CLUSTERRA_SQS_URL", "")


def main():
    if len(sys.argv) < 2:
        print("Usage: clusterra-hook.py <event_type> [additional_data_json]")
        sys.exit(1)
    
    event_type = sys.argv[1]
    additional_data = {}
    
    if len(sys.argv) > 2:
        try:
            additional_data = json.loads(sys.argv[2])
        except json.JSONDecodeError:
            pass
    
    if not QUEUE_URL:
        print("CLUSTERRA_SQS_URL not set, skipping event")
        sys.exit(0)
    
    # Build event from Slurm environment
    event = {
        "ts": datetime.now().isoformat(),
        "event": event_type,
        "job_id": os.environ.get("SLURM_JOB_ID"),
        "user": os.environ.get("SLURM_JOB_USER"),
        "partition": os.environ.get("SLURM_JOB_PARTITION"),
        "node": os.environ.get("SLURMD_NODENAME"),
        "exit_code": os.environ.get("SLURM_JOB_EXIT_CODE"),
        "state": os.environ.get("SLURM_JOB_STATE"),
        "nodes": os.environ.get("SLURM_JOB_NODELIST"),
    }
    
    # Remove None values and merge additional data
    event = {k: v for k, v in event.items() if v is not None}
    event.update(additional_data)
    
    # Send to SQS
    try:
        sqs = boto3.client("sqs")
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(event)
        )
    except Exception as e:
        # Don't fail the hook - just log
        print(f"Warning: Failed to send event: {e}")


if __name__ == "__main__":
    main()
