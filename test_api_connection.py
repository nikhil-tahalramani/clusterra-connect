#!/usr/bin/env python3
"""
Standalone script to test Clusterra API Connection (Phase 4 Logic)
"""
import json
import boto3
import requests
import subprocess
import os
import sys
from pathlib import Path
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import base64
import argparse

DEFAULT_API_URL = "https://api.clusterra.cloud"

def get_tfvars():
    vars = {}
    path = Path("generated/terraform.tfvars")
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'): continue
            if '=' in line:
                key, val = line.split('=', 1)
                vars[key.strip()] = val.strip().strip('"')
    return vars

def get_tofu_output(name):
    try:
        result = subprocess.run(['tofu', 'output', '-json', name], capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception as e:
        print(f"Error reading tofu output: {e}")
    return {}

def generate_sts_token(session):
    region = session.region_name or "us-east-1"
    url = f"https://sts.{region}.amazonaws.com/"
    
    request = AWSRequest(
        method="POST",
        url=url,
        data="Action=GetCallerIdentity&Version=2011-06-15",
        headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    SigV4Auth(session.get_credentials(), "sts", region).add_auth(request)
    
    token_data = {
        "url": request.url,
        "headers": dict(request.headers),
        "body": request.data
    }
    
    return base64.b64encode(json.dumps(token_data).encode()).decode()

def run_diagnostics(hostname):
    import socket
    import shutil
    
    print(f"\n--- Network Diagnostics for {hostname} ---")
    
    # 1. DNS Resolution
    try:
        ip = socket.gethostbyname(hostname)
        print(f"✅ DNS Resolution: {hostname} -> {ip}")
    except socket.gaierror as e:
        print(f"❌ DNS Resolution Failed: {e}")
        return False

    # 2. TCP Connect (Port 443)
    print(f"Testing TCP connection to {ip}:443...")
    try:
        sock = socket.create_connection((ip, 443), timeout=5)
        sock.close()
        print(f"✅ TCP Connection Successful")
    except socket.timeout:
        print(f"❌ TCP Connection Timed Out (5s)")
        print("   -> Possible Firewall or VPN issue.")
        return False
    except ConnectionRefusedError:
        print(f"❌ Connection Refused")
        return False
    except Exception as e:
        print(f"❌ Connection Failed: {e}")
        return False
        
    return True

def main():
    parser = argparse.ArgumentParser(description="Test Clusterra API Connection")
    parser.add_argument('--profile', help="AWS profile to use", default=None)
    args = parser.parse_args()

    print("--- Clusterra API Connection Tester ---")
    
    # Pre-check Network
    host = DEFAULT_API_URL.replace("https://", "").replace("/", "")
    run_diagnostics(host)
    
    # 1. Load Config
    tfvars = get_tfvars()
    if not tfvars:
        print("❌ Could not read generated/terraform.tfvars")
        return

    cluster_id = tfvars.get('cluster_id')
    tenant_id = tfvars.get('tenant_id')
    cluster_name = tfvars.get('cluster_name')
    region = tfvars.get('region')
    
    print(f"\nCluster ID: {cluster_id}")
    print(f"Tenant ID: {tenant_id}")
    print(f"Region: {region}")
    
    # 2. Get Tofu Output
    print("\nReading Tofu Output...")
    onboarding = get_tofu_output('clusterra_onboarding')
    if not onboarding:
        print("❌ Could not read 'clusterra_onboarding' output from tofu. Run in module root.")
        return

    # 3. Build Payload
    payload = {
        "cluster_id": cluster_id,
        "cluster_name": cluster_name,
        "aws_account_id": onboarding.get("aws_account_id", ""),
        "region": region,
        "lattice_service_endpoint": onboarding.get("lattice_service_endpoint", ""),
        "lattice_service_arn": onboarding.get("lattice_service_arn", ""),
        "lattice_service_network_id": onboarding.get("lattice_service_network_id", ""),
        "slurm_port": int(onboarding.get("slurm_port", 443)),
        "slurm_jwt_secret_arn": onboarding.get("slurm_jwt_secret_arn", ""),
        "iam_role_arn": onboarding.get("role_arn", ""),
        "iam_external_id": onboarding.get("external_id", ""),
        "head_node_instance_id": onboarding.get("head_node_instance_id")
    }
    
    print("\nPayload:")
    print(json.dumps(payload, indent=2))
    
    # 4. Auth
    print("\nGenerating STS Token...")
    try:
        session = boto3.Session(profile_name=args.profile, region_name=region)
        
        # Verify Identity
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        print(f"DEBUG: Active Identity ARN: {identity['Arn']}")
        print(f"DEBUG: Active Account ID:   {identity['Account']}")
        
        sts_token = generate_sts_token(session)
        print("✓ Token generated")
        
        # Determine URL
        url = f"{DEFAULT_API_URL}/v1/internal/connect/{tenant_id}"
        
        # Export reproduction script
        with open("reproduce_curl.sh", "w") as f:
            f.write("#!/bin/bash\n")
            f.write(f"curl -v -X POST {url} \\\n")
            f.write(f"  -H 'Content-Type: application/json' \\\n")
            f.write(f"  -H 'X-AWS-STS-Token: {sts_token}' \\\n")
            f.write(f"  -d '{json.dumps(payload)}'\n")
        
        os.chmod("reproduce_curl.sh", 0o755)
        print("✓ Generated reproduce_curl.sh")

    except Exception as e:
        print(f"❌ Failed to generate STS token: {e}")
        return

    # 5. Send Request
    print(f"\nSending POST to {url} ...")
    
    # helper for RAM acceptance
    def accept_ram_invitation(session):
        ram = session.client('ram')
        try:
            resp = ram.get_resource_share_invitations()
            invites = resp.get('resourceShareInvitations', [])
            if not invites: return False
            for invite in invites:
                arn = invite['resourceShareInvitationArn']
                print(f"⚡ Found RAM Invitation for '{invite['resourceShareName']}' from {invite['senderAccountId']}")
                print(f"   Accepting {arn}...")
                ram.accept_resource_share_invitation(resourceShareInvitationArn=arn)
                print(f"✅ Accepted RAM invitation")
                return True
        except Exception as e:
            print(f"⚠️ Error checking RAM: {e}")
        return False

    try:
        resp = requests.post(url, json=payload, headers={"X-AWS-STS-Token": sts_token}, timeout=30)
    except requests.exceptions.Timeout:
        print("\n⚠️ Request Timed Out (Suspecting RAM Share pending...)")
        resp = None

    # Check/Retry logic
    if resp and resp.status_code in [201, 409]:
        print(f"\n✅ SUCCESS: Registration successful (Status: {resp.status_code})")
    else:
        # Check RAM and retry
        print("\nChecking for pending RAM invitation...")
        if accept_ram_invitation(session):
            print("\n🔄 Retrying Registration after RAM acceptance...")
            import time
            time.sleep(5)
            try:
                resp = requests.post(url, json=payload, headers={"X-AWS-STS-Token": sts_token}, timeout=60)
                if resp.status_code == 201:
                    print("\n✅ SUCCESS: Registration successful")
                else:
                    print(f"\n❌ FAILURE: Registration failed with {resp.status_code}: {resp.text}")
            except Exception as e:
                print(f"\n❌ FAILURE: Retry Error: {e}")
        else:
            if resp:
                print(f"\n❌ FAILURE: Registration failed with {resp.status_code}: {resp.text}")
            else:
                 print("\n❌ FAILURE: Request Timed Out and no RAM invite found.")

if __name__ == "__main__":
    main()
