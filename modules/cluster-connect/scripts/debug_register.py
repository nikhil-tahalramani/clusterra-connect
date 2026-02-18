import json
import os
import sys
import boto3
import requests
import base64
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from pathlib import Path

# Config
DEFAULT_API_URL = "https://api.clusterra.cloud"
CLUSTERRA_ENV = os.environ.get("CLUSTERRA_ENV", "prod")
if CLUSTERRA_ENV == "dev":
    DEFAULT_API_URL = "https://dev-api.clusterra.cloud"

print(f"Env: {CLUSTERRA_ENV}")
print(f"API: {DEFAULT_API_URL}")


def generate_sts_token(session: boto3.Session) -> str:
    """Generate presigned STS GetCallerIdentity token."""
    region = session.region_name or "us-east-1"
    url = f"https://sts.{region}.amazonaws.com/"

    request = AWSRequest(
        method="POST",
        url=url,
        data="Action=GetCallerIdentity&Version=2011-06-15",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    SigV4Auth(session.get_credentials(), "sts", region).add_auth(request)

    token_data = {
        "url": request.url,
        "headers": dict(request.headers),
        "body": request.data,
    }
    return base64.b64encode(json.dumps(token_data).encode()).decode()


def main():
    session = boto3.Session()
    print(f"AWS Profile: {session.profile_name}")
    print(f"AWS Region: {session.region_name}")

    # Read Tfvars for registered check
    tfvars_path = Path("generated/terraform.tfvars")
    if not tfvars_path.exists():
        print("Error: generated/terraform.tfvars not found")
        sys.exit(1)

    tfvars = tfvars_path.read_text()
    cluster_id = None
    tenant_id = None
    region = session.region_name

    for line in tfvars.split("\n"):
        if line.strip().startswith("cluster_id"):
            cluster_id = line.split("=")[1].strip().strip('"')
        if line.strip().startswith("tenant_id"):
            tenant_id = line.split("=")[1].strip().strip('"')

    if not cluster_id or not tenant_id:
        print("Error: Could not find cluster_id or tenant_id in tfvars")
        sys.exit(1)

    print(f"Cluster ID: {cluster_id}")
    print(f"Tenant ID: {tenant_id}")

    # Read Tofu Output
    try:
        import subprocess

        result = subprocess.run(
            ["tofu", "output", "-json", "clusterra_onboarding"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print("Error running tofu output")
            print(result.stderr)
            sys.exit(1)
        onboarding = json.loads(result.stdout)
    except Exception as e:
        print(f"Error reading tofu output: {e}")
        sys.exit(1)

    # Payload
    payload = {
        "cluster_id": cluster_id,
        "cluster_name": f"cluster-{cluster_id}",  # Fallback name
        "aws_account_id": onboarding.get("aws_account_id", ""),
        "region": region,
        "lattice_service_endpoint": onboarding.get("lattice_service_endpoint", ""),
        "lattice_service_arn": onboarding.get("lattice_service_arn", ""),
        "lattice_service_network_id": onboarding.get("lattice_service_network_id", ""),
        "slurm_port": int(onboarding.get("slurm_port", 443)),
        "slurm_jwt_secret_arn": onboarding.get("slurm_jwt_secret_arn", ""),
        "iam_role_arn": onboarding.get("role_arn", ""),
        "iam_external_id": onboarding.get("external_id", ""),
        "head_node_instance_id": onboarding.get("head_node_instance_id"),
        # Add required params even if empty/wrong to debug validation
        "files_bucket": onboarding.get("files_bucket"),
        "efs_id": onboarding.get("efs_id"),
    }

    # Hack: get cluster name from somewhere, maybe just hardcode or ask user?
    # Actually, install.py passes cluster_name. We don't have it easily here without reparsing config.
    # Let's try to get it from TF output if available, or just use a dummy one since we are testing registration.
    # Wait, cluster_name matters for display.
    # We can try to grep it from the config yaml if needed.
    # For quick debug, "debug-cluster" is fine.

    sts_token = generate_sts_token(session)

    url = f"{DEFAULT_API_URL}/v1/internal/connect/{tenant_id}"
    print(f"\nPOST {url}")
    # print(json.dumps(payload, indent=2))

    try:
        resp = requests.post(
            url, json=payload, headers={"X-AWS-STS-Token": sts_token}, timeout=30
        )
        print(f"\nStatus: {resp.status_code}")
        print(f"Response: {resp.text}")

    except Exception as e:
        print(f"Request failed: {e}")


if __name__ == "__main__":
    main()
