"""
Clusterra Event Shipper Lambda

Triggered by SQS, batches events and ships to Clusterra API.
Deployed in CUSTOMER's AWS account via OpenTofu.
"""

import json
import os
import urllib.request
import urllib.error
from datetime import datetime

# Configuration from environment
CLUSTERRA_API_URL = os.environ.get("CLUSTERRA_API_URL", "https://api.clusterra.cloud")
CLUSTER_ID = os.environ["CLUSTER_ID"]
TENANT_ID = os.environ["TENANT_ID"]


def handler(event, context):
    """
    Process SQS messages and ship to Clusterra API.
    
    SQS sends batches of up to 10 messages per invocation.
    """
    records = event.get("Records", [])
    if not records:
        return {"statusCode": 200, "body": "No records"}
    
    # Parse events from SQS messages
    events = []
    for record in records:
        try:
            body = json.loads(record["body"])
            
            # CloudWatch events have nested structure
            if "detail-type" in body:
                body = transform_cloudwatch_event(body)
            
            events.append(body)
        except (json.JSONDecodeError, KeyError) as e:
            print(f"Error parsing record: {e}")
            continue
    
    if not events:
        return {"statusCode": 200, "body": "No valid events"}
    
    # Group events by type for batch API
    job_updates = []
    node_updates = []
    cluster_updates = []
    
    for evt in events:
        event_type = evt.get("event", "")
        
        if event_type.startswith("job."):
            job_updates.append(transform_job_event(evt))
        elif event_type.startswith("node."):
            node_updates.append(transform_node_event(evt))
        elif event_type.startswith("cluster."):
            cluster_updates.append(transform_cluster_event(evt))
    
    # Build batch request
    tables = {}
    if job_updates:
        tables["jobs"] = {"update": job_updates}
    if node_updates:
        tables["nodes"] = {"upsert": node_updates}
    if cluster_updates:
        tables["clusters"] = {"update": cluster_updates}
    
    payload = {
        "cluster_id": CLUSTER_ID,
        "tables": tables
    }
    
    # Ship to Clusterra API
    try:
        response = call_clusterra_api("/v1/internal/batch", payload)
        print(f"Shipped {len(events)} events: {response}")
        return {"statusCode": 200, "body": json.dumps(response)}
    except Exception as e:
        print(f"Error shipping events: {e}")
        # Re-raise to let SQS retry
        raise


def transform_cloudwatch_event(cw_event):
    """Transform CloudWatch event to Clusterra event format."""
    detail_type = cw_event.get("detail-type", "")
    detail = cw_event.get("detail", {})
    timestamp = cw_event.get("time", datetime.utcnow().isoformat())
    
    # EC2 state changes
    if detail_type == "EC2 Instance State-change Notification":
        state = detail.get("state", "unknown")
        instance_id = detail.get("instance-id")
        
        # Map EC2 states to our event types
        state_map = {
            "running": "cluster.state.started",
            "stopped": "cluster.state.stopped",
            "stopping": "cluster.state.stopping",
            "pending": "cluster.state.starting",
        }
        
        return {
            "ts": timestamp,
            "event": state_map.get(state, f"cluster.state.{state}"),
            "instance_id": instance_id,
            "detail": detail
        }
    
    # ASG events
    elif detail_type == "EC2 Instance Launch Successful":
        return {
            "ts": timestamp,
            "event": "node.launched",
            "instance_id": detail.get("EC2InstanceId"),
            "asg_name": detail.get("AutoScalingGroupName"),
        }
    
    elif detail_type == "EC2 Instance Terminate Successful":
        return {
            "ts": timestamp,
            "event": "node.terminated",
            "instance_id": detail.get("EC2InstanceId"),
            "asg_name": detail.get("AutoScalingGroupName"),
        }
    
    # Spot interruption
    elif detail_type == "EC2 Spot Instance Interruption Warning":
        return {
            "ts": timestamp,
            "event": "node.spot_interrupted",
            "instance_id": detail.get("instance-id"),
            "action": detail.get("instance-action"),
        }
    
    # Unknown event type - pass through
    return {
        "ts": timestamp,
        "event": f"unknown.{detail_type}",
        "detail": detail
    }


def transform_job_event(evt):
    """Transform job event to batch API format."""
    event_type = evt.get("event", "")
    
    update = {
        "job_id": str(evt.get("job_id", "")),
    }
    
    if event_type == "job.started":
        update["state"] = "running"
        update["started_at"] = evt.get("ts")
        update["node"] = evt.get("node")
    elif event_type == "job.completed":
        update["state"] = "completed"
        update["completed_at"] = evt.get("ts")
        update["exit_code"] = evt.get("exit_code", 0)
    elif event_type == "job.failed":
        update["state"] = "failed"
        update["completed_at"] = evt.get("ts")
        update["exit_code"] = evt.get("exit_code", 1)
    elif event_type == "job.cancelled":
        update["state"] = "cancelled"
        update["completed_at"] = evt.get("ts")
    elif event_type == "job.timeout":
        update["state"] = "timeout"
        update["completed_at"] = evt.get("ts")
    
    return update


def transform_node_event(evt):
    """Transform node event to batch API format."""
    return {
        "node_id": evt.get("instance_id", ""),
        "ec2_instance_id": evt.get("instance_id"),
        "ec2_state": "running" if evt.get("event") == "node.launched" else "terminated",
        "asg_name": evt.get("asg_name"),
    }


def transform_cluster_event(evt):
    """Transform cluster event to batch API format."""
    event_type = evt.get("event", "")
    state_map = {
        "cluster.state.started": "running",
        "cluster.state.stopped": "stopped",
        "cluster.state.starting": "starting",
        "cluster.state.stopping": "stopping",
    }
    return {
        "state": state_map.get(event_type, "unknown"),
        "instance_id": evt.get("instance_id"),
    }


def call_clusterra_api(path, payload):
    """Call Clusterra API with proper headers."""
    url = f"{CLUSTERRA_API_URL}{path}"
    
    data = json.dumps(payload).encode("utf-8")
    
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-Tenant-ID": TENANT_ID,
            "X-Cluster-ID": CLUSTER_ID,
        },
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8") if e.fp else ""
        print(f"API error {e.code}: {error_body}")
        raise
