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
CLUSTER_NAME = os.environ.get("CLUSTER_NAME")
HEAD_NODE_INSTANCE_ID = os.environ.get("HEAD_NODE_INSTANCE_ID")
SAAS_BUS_ARN = os.environ.get("SAAS_BUS_ARN")


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda Forwarder Handler.

    1. Receives any event from Local Default Bus.
    2. Filters: Must belong to this cluster (tag check for EC2/ASG, trusted for Slurm).
    3. Enriches: Adds cluster_id, tenant_id, cluster_name to detail.
    4. Classifies: Prefixes detail-type with resource type (cluster.* or node.*).
    5. Forwards raw event to SaaS Event Bus.

    Source mapping:
      - EC2 / ASG / Spot / Fleet events  →  clusterra.infra
      - Slurm hook events                →  clusterra.slurm
      - (Future: EFS / FSx events        →  clusterra.infra)
    """
    print(f"Received event: {json.dumps(event)}")

    source = event.get("source", "")
    detail = event.get("detail", {})
    original_detail_type = event.get("detail-type", "")

    # ─── 1. Route by source ───────────────────────────────────────────────────

    if source == "clusterra.slurm":
        # Slurm hook events: trusted, forward as-is
        fwd_source = "clusterra.slurm"
        fwd_detail_type = original_detail_type

    elif _is_infra_event(source):
        # Infrastructure event (EC2, ASG, Spot, Fleet, etc.)
        instance_id = _extract_instance_id(detail)

        if not instance_id:
            print(f"Skipping: Could not find instance-id in {source} event")
            return {"status": "skipped", "reason": "no_instance_id"}

        if not _is_cluster_instance(instance_id):
            print(
                f"Skipping: Instance {instance_id} does not belong to cluster {CLUSTER_ID}"
            )
            return {"status": "skipped", "reason": "tag_mismatch"}

        # Classify: head node → cluster, compute → node
        resource_type = "cluster" if instance_id == HEAD_NODE_INSTANCE_ID else "node"

        fwd_source = "clusterra.infra"
        fwd_detail_type = f"{resource_type}.{original_detail_type}"

        print(f"Classified: instance={instance_id} → {resource_type}")

    else:
        print(f"Skipping: Unhandled source {source}")
        return {"status": "skipped", "reason": "unhandled_source"}

    # ─── 2. Enrich detail ─────────────────────────────────────────────────────

    detail["cluster_id"] = CLUSTER_ID
    detail["tenant_id"] = TENANT_ID
    detail["cluster_name"] = CLUSTER_NAME

    # ─── 3. Forward ───────────────────────────────────────────────────────────

    try:
        entry = {
            "Source": fwd_source,
            "DetailType": fwd_detail_type,
            "Detail": json.dumps(detail),
            "Resources": event.get("resources", []),
            "EventBusName": SAAS_BUS_ARN,
        }

        response = events_client.put_events(Entries=[entry])

        failed_entry_count = response.get("FailedEntryCount", 0)
        if failed_entry_count > 0:
            print(f"Error forwarding event: {json.dumps(response)}")
            raise Exception(f"Failed to forward event to {SAAS_BUS_ARN}")

        print(f"Forwarded → {fwd_source} / {fwd_detail_type}")
        return {
            "status": "forwarded",
            "source": fwd_source,
            "detail_type": fwd_detail_type,
            "request_id": response.get("ResponseMetadata", {}).get("RequestId"),
        }

    except Exception as e:
        print(f"Exception forwarding event: {str(e)}")
        raise


# ─── Helpers ──────────────────────────────────────────────────────────────────


def _is_infra_event(source: str) -> bool:
    """Check if event source is an infrastructure provider we forward."""
    return source in (
        "aws.ec2",
        "aws.autoscaling",
        "aws.ec2fleet",
        "aws.ec2spotfleet",
        # Future: "aws.efs", "aws.fsx", etc.
    )


def _extract_instance_id(detail: Dict[str, Any]) -> str | None:
    """Extract instance ID from various AWS event shapes."""
    # EC2 Instance State-change Notification
    # EC2 Spot Instance Interruption Warning
    instance_id = detail.get("instance-id")
    if instance_id:
        return instance_id

    # ASG events (Launch/Terminate Successful, etc.)
    instance_id = detail.get("EC2InstanceId")
    if instance_id:
        return instance_id

    # EC2 Fleet / Spot Fleet instance changes
    instances = detail.get("instances", [])
    if instances and isinstance(instances, list):
        first = instances[0]
        if isinstance(first, dict):
            return first.get("instanceId")
        return first

    return None


def _is_cluster_instance(instance_id: str) -> bool:
    """Check if EC2 instance has the correct parallelcluster:cluster-name tag."""
    try:
        response = ec2_client.describe_tags(
            Filters=[
                {"Name": "resource-id", "Values": [instance_id]},
                {"Name": "key", "Values": ["parallelcluster:cluster-name"]},
            ]
        )

        if not CLUSTER_NAME:
            print("Error: CLUSTER_NAME env var not set")
            return False

        for tag in response.get("Tags", []):
            if tag["Value"] == CLUSTER_NAME:
                return True

        return False

    except Exception as e:
        print(f"Error describing tags for {instance_id}: {str(e)}")
        return False
