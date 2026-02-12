import json
import os
import boto3
from typing import Dict, Any

# Initialize clients outside handler for reuse
ec2_client = boto3.client("ec2")
events_client = boto3.client("events")

# Environment variables
CLUSTER_ID = os.environ.get("CLUSTER_ID")
TENANT_ID = os.environ.get("TENANT_ID")
SAAS_BUS_ARN = os.environ.get("SAAS_BUS_ARN")


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda Forwarder Handler.

    1. Receives event from Local Default Bus (EC2 State Change or Slurm Hook).
    2. Filters EC2 events: Must have tag parallelcluster:cluster-name == os.environ['CLUSTER_NAME'].
    3. Enriches event: Adds cluster_id, tenant_id, and cluster_name to detail.
    4. Forwards to SaaS Event Bus.
    """
    print(f"Received event: {json.dumps(event)}")

    source = event.get("source")
    detail = event.get("detail", {})

    # ─── 1. Filter Logic ──────────────────────────────────────────────────────

    if source == "aws.ec2" or source == "aws.autoscaling":
        # Extract Instance ID based on event type
        instance_id = detail.get("instance-id")  # EC2 State Change
        if not instance_id:
            instance_id = detail.get("EC2InstanceId")  # ASG Events

        if not instance_id:
            # Maybe Spot Interruption?
            instance_id = detail.get("instance-id")

        if not instance_id:
            print(f"Skipping: Could not find instance-id in {source} event")
            return {"status": "skipped", "reason": "no_instance_id"}

        # Verify instance belongs to this cluster
        if not _is_cluster_instance(instance_id):
            print(
                f"Skipping: Instance {instance_id} does not belong to cluster {CLUSTER_ID}"
            )
            return {"status": "skipped", "reason": "tag_mismatch"}

    elif source == "clusterra.slurm":
        # Trust events from our own hooks
        pass

    else:
        print(f"Skipping: Unhandled source {source}")
        return {"status": "skipped", "reason": "unhandled_source"}

    # ─── 2. Enrich Logic ──────────────────────────────────────────────────────

    # Inject identity into detail
    detail["cluster_id"] = CLUSTER_ID
    detail["tenant_id"] = TENANT_ID
    # Also add cluster_name for easier human debugging
    detail["cluster_name"] = os.environ.get("CLUSTER_NAME")

    # Update event object
    event["detail"] = detail

    # ─── 3. Forward Logic ─────────────────────────────────────────────────────

    try:
        # Construct entry for PutEvents
        entry = {
            "Time": event.get("time"),
            "Source": source,
            "Resources": event.get("resources", []),
            "DetailType": event.get("detail-type"),
            "Detail": json.dumps(detail),
            "EventBusName": SAAS_BUS_ARN,
        }

        response = events_client.put_events(Entries=[entry])

        failed_entry_count = response.get("FailedEntryCount", 0)
        if failed_entry_count > 0:
            print(f"Error forwarding event: {json.dumps(response)}")
            raise Exception(f"Failed to forward event to {SAAS_BUS_ARN}")

        print(f"Successfully forwarded event to {SAAS_BUS_ARN}")
        return {
            "status": "forwarded",
            "request_id": response.get("ResponseMetadata", {}).get("RequestId"),
        }

    except Exception as e:
        print(f"Exception forwarding event: {str(e)}")
        raise


def _is_cluster_instance(instance_id: str) -> bool:
    """Check if EC2 instance has the correct parallelcluster:cluster-name tag."""
    try:
        response = ec2_client.describe_tags(
            Filters=[
                {"Name": "resource-id", "Values": [instance_id]},
                {"Name": "key", "Values": ["parallelcluster:cluster-name"]},
            ]
        )

        # ParallelCluster tags nodes with parallelcluster:cluster-name = <cluster_name>
        # We verify this matches the CLUSTER_NAME env var
        cluster_name = os.environ.get("CLUSTER_NAME")
        if not cluster_name:
            print("Error: CLUSTER_NAME env var not set")
            return False

        for tag in response.get("Tags", []):
            if tag["Value"] == cluster_name:
                return True

        return False

    except Exception as e:
        print(f"Error describing tags for {instance_id}: {str(e)}")
        # Fail safe: Do not forward if we can't verify
        return False
