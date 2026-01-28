#!/usr/bin/env python3
"""
Clusterra Connect Installer
Refer to: implementation_plan.md for the 6-Phase Tofu-Centric Flow.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# Dependency Check
try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound
except ImportError:
    print("❌ boto3 is required. Install with: pip install boto3")
    sys.exit(1)

try:
    import questionary
    from questionary import Style
except ImportError:
    print("❌ questionary is required. Install with: pip install questionary")
    sys.exit(1)

try:
    import requests
except ImportError:
    print("❌ requests is required. Install with: pip install requests")
    sys.exit(1)

try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn
except ImportError:
    print("❌ rich is required. Install with: pip install rich")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CLUSTERRA_AWS_ACCOUNT_ID = "306847926740"
DEFAULT_API_URL = "https://api.clusterra.cloud"

console = Console()

PROMPT_STYLE = Style([
    ('qmark', 'fg:cyan bold'),
    ('question', 'bold'),
    ('answer', 'fg:green'),
    ('pointer', 'fg:cyan bold'),
    ('highlighted', 'fg:cyan'),
    ('selected', 'fg:green'),
])

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS (Preserved)
# ─────────────────────────────────────────────────────────────────────────────

def check_tool_installed(tool: str, install_hint: str) -> tuple[bool, str | None]:
    """Check if a CLI tool is installed and return version."""
    try:
        cmd = [tool, '--version'] if tool in ['aws', 'node'] else [tool, 'version']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        if result.returncode == 0:
            output = result.stdout.strip() or result.stderr.strip()
            if output.startswith('{'):
                try:
                    data = json.loads(output)
                    return True, data.get('version', 'unknown')
                except json.JSONDecodeError:
                    pass
            return True, output.split('\n')[0]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    
    # Common fallback paths
    common_paths = [
        Path.home() / ".local/bin",
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path.home() / "Library/Python/3.10/bin", # Common mac pcluster location
        Path.home() / "Library/Python/3.11/bin",
    ]
    
    for search_path in common_paths:
        tool_path = search_path / tool
        if tool_path.exists() and os.access(tool_path, os.X_OK):
             current_path = os.environ.get("PATH", "")
             if str(search_path) not in current_path.split(os.pathsep):
                 os.environ["PATH"] = f"{search_path}{os.pathsep}{current_path}"
             return True, f"Found in {search_path}"

    return False, install_hint

def run_preflight_checks() -> bool:
    """Run pre-flight checks for required CLI tools."""
    checks = [
        ('aws', 'pip install awscli OR brew install awscli'),
        ('tofu', 'brew install opentofu OR https://opentofu.org/docs/intro/install/'),
        ('node', 'brew install node OR https://nodejs.org/'),
        ('pcluster', 'pip install aws-parallelcluster'),
    ]
    
    all_passed = True
    console.print("[bold]Pre-flight Checks[/bold]")
    for tool, hint in checks:
        installed, info = check_tool_installed(tool, hint)
        if installed:
            console.print(f"  [green]✓[/green] {tool}: [dim]{info}[/dim]")
        else:
            console.print(f"  [red]✗[/red] {tool}: [red]not found[/red]")
            console.print(f"    [dim]Install: {hint}[/dim]")
            all_passed = False
    console.print()
    return all_passed

def get_aws_session(profile: str | None = None, region: str | None = None) -> boto3.Session:
    try:
        return boto3.Session(profile_name=profile, region_name=region)
    except ProfileNotFound:
        console.print(f"[red]❌ AWS profile '{profile}' not found[/red]")
        sys.exit(1)

def list_vpcs(session: boto3.Session) -> list[dict]:
    ec2 = session.client('ec2')
    try:
        response = ec2.describe_vpcs()
        return [{
            'id': v['VpcId'],
            'name': next((t['Value'] for t in v.get('Tags', []) if t['Key'] == 'Name'), 'unnamed'),
            'cidr': v['CidrBlock']
        } for v in response['Vpcs']]
    except ClientError:
        return []

def list_subnets(session: boto3.Session, vpc_id: str) -> list[dict]:
    ec2 = session.client('ec2')
    try:
        response = ec2.describe_subnets(Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}])
        return [{
            'id': s['SubnetId'],
            'name': next((t['Value'] for t in s.get('Tags', []) if t['Key'] == 'Name'), 'unnamed'),
            'az': s['AvailabilityZone'],
            'public': s.get('MapPublicIpOnLaunch', False),
        } for s in response['Subnets']]
    except ClientError:
        return []

def list_ssh_keys(session: boto3.Session) -> list[str]:
    ec2 = session.client('ec2')
    try:
        return [kp['KeyName'] for kp in ec2.describe_key_pairs()['KeyPairs']]
    except ClientError:
        return []

# ─────────────────────────────────────────────────────────────────────────────
# TOFU & PCLUSTER WRAPPERS
# ─────────────────────────────────────────────────────────────────────────────

def run_tofu(args: list[str], description: str) -> bool:
    """Run tofu command with UI feedback."""
    cmd = ['tofu'] + args
    console.print(f"[cyan]→ {' '.join(cmd)}[/cyan]")
    
    # Simple spinner for UI niceness
    with Progress(SpinnerColumn(), TextColumn("[progress.description]{task.description}"), console=console) as progress:
        task = progress.add_task(description, total=None)
        result = subprocess.run(cmd, cwd=Path.cwd()) # Allow output to stream to console
        if result.returncode == 0:
            progress.update(task, description=f"[green]✓ {description} complete[/green]")
            return True
        else:
            progress.update(task, description=f"[red]❌ {description} failed[/red]")
            return False

def get_tofu_output(name: str, as_json: bool = False) -> str | dict | None:
    try:
        args = ['tofu', 'output', '-json', name] if as_json else ['tofu', 'output', '-raw', name]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode == 0:
            out = result.stdout.strip()
            return json.loads(out) if as_json else out
    except Exception:
        pass
    return None

def get_pcluster_status(cluster_name: str, session: boto3.Session) -> str:
    """Get CloudFormation stack status for pcluster."""
    cfn = session.client('cloudformation')
    try:
        response = cfn.describe_stacks(StackName=cluster_name)
        if response['Stacks']:
            return response['Stacks'][0]['StackStatus']
    except ClientError:
        return "NOT_FOUND"
    return "NOT_FOUND"

def get_head_node_id(cluster_name: str, session: boto3.Session) -> str | None:
    """Fetch Head Node Instance ID from CloudFormation resources."""
    cfn = session.client('cloudformation')
    try:
        response = cfn.describe_stack_resources(StackName=cluster_name)
        for r in response['StackResources']:
            if r['LogicalResourceId'] == 'HeadNode':
                return r['PhysicalResourceId']
    except ClientError:
        pass
    return None

# ─────────────────────────────────────────────────────────────────────────────
# PHASES (Granular)
# ─────────────────────────────────────────────────────────────────────────────

def phase_1a_config(cluster_name: str, dry_run: bool) -> bool:
    """Phase 1a: Generate Config YAML via Tofu."""
    console.print(Panel("[bold]Phase 1a: Cluster Config[/bold]", border_style="blue"))
    config_file = Path.cwd() / "generated" / f"{cluster_name}-config.yaml"
    
    if config_file.exists():
        console.print(f"[green]✓ Config already exists:[/green] {config_file}")
        return True
    
    if dry_run:
        console.print("[yellow]Dry Run: Would generate config via tofu[/yellow]")
        return True

    # Run tofu init unconditionally to ensure lockfile consistency
    console.print("[cyan]→ tofu init[/cyan]")
    if subprocess.run(['tofu', 'init'], cwd=Path.cwd()).returncode != 0:
        return False

    return run_tofu(['apply', '-target', 'module.parallelcluster', '-var-file=generated/terraform.tfvars', '-auto-approve'], "Generating Cluster Config")

def phase_1b_create(cluster_name: str, region: str, dry_run: bool, session: boto3.Session) -> bool:
    """Phase 1b: Create Cluster via Pcluster CLI."""
    console.print(Panel("[bold]Phase 1b: Cluster Creation[/bold]", border_style="blue"))
    
    status = get_pcluster_status(cluster_name, session)
    if status == 'CREATE_COMPLETE':
        console.print(f"[green]✓ Cluster '{cluster_name}' is active[/green]")
        return True
    elif status == 'NOT_FOUND':
        config_file = Path.cwd() / "generated" / f"{cluster_name}-config.yaml"
        if not config_file.exists():
             if dry_run:
                 console.print(f"[yellow]Dry Run: Config file missing ({config_file}), assuming Phase 1a created it.[/yellow]")
             else:
                 console.print(f"[red]❌ Config file missing: {config_file}[/red]")
                 return False

        if dry_run:
             console.print("[yellow]Dry Run: Would run pcluster create-cluster[/yellow]")
             return True

        console.print(f"[cyan]→ pcluster create-cluster --cluster-name {cluster_name} ...[/cyan]")
        cmd = [
            'pcluster', 'create-cluster',
            '--cluster-name', cluster_name,
            '--cluster-configuration', str(config_file),
            '--region', region
        ]
        if subprocess.run(cmd).returncode != 0:
            console.print("[red]❌ Cluster creation command failed[/red]")
            return False
        
        # Fall through to wait loop
        status = 'CREATE_IN_PROGRESS'

    # Wait Loop
    if 'IN_PROGRESS' in status:
        console.print(f"[dim]Waiting for cluster creation (Status: {status})...[/dim]")
        with Progress(SpinnerColumn(), TextColumn("{task.description}"), TimeElapsedColumn(), console=console) as progress:
            task = progress.add_task("Creating Cluster...", total=None)
            while 'IN_PROGRESS' in status:
                time.sleep(30)
                status = get_pcluster_status(cluster_name, session)
                progress.update(task, description=f"Cluster Status: {status}")
                if status == 'CREATE_COMPLETE':
                    console.print("[green]✓ Cluster created successfully![/green]")
                    return True
                if 'FAILED' in status:
                    console.print(f"[red]❌ Cluster creation failed with status: {status}[/red]")
                    return False
    
    return False

def phase_2a_connect_infra(cluster_name: str, dry_run: bool, session: boto3.Session) -> bool:
    """Phase 2a: Connectivity Infra (Tofu)."""
    console.print(Panel("[bold]Phase 2a: Connectivity[/bold]", border_style="blue"))
    
    # 1. Fetch Head Node ID (Dynamic Check)
    head_node_id = get_head_node_id(cluster_name, session)

    # Ensure tofu is initialized (critical for "Existing Cluster" path which skips Phase 1a)
    if not dry_run:
        console.print("[cyan]→ tofu init[/cyan]")
        subprocess.run(['tofu', 'init'], cwd=Path.cwd(), capture_output=True)
    
    if not head_node_id:
        if dry_run:
            console.print("[yellow]Dry Run: Mocking Head Node ID for verification[/yellow]")
            head_node_id = "i-MOCKHEADNODE12345"
        else:
            console.print("[red]❌ Could not find Head Node Instance ID. Is cluster active?[/red]")
            return False
    
    console.print(f"[dim]Head Node ID: {head_node_id}[/dim]")

    # 2. FRONTLOAD: Attach SSM policy early (agent registers during Tofu apply)
    if not dry_run:
        ensure_ssm_permissions(head_node_id, session)
        console.print("[dim]SSM policy attached, agent registering in background...[/dim]")

    # 3. Update tfvars with this ID (so Tofu knows about it)
    update_tfvars({'head_node_instance_id': head_node_id})

    # 4. Run Tofu apply (takes ~5 min, SSM registers in parallel)
    if dry_run:
        console.print("[yellow]Dry Run: Would run tofu apply for connectivity[/yellow]")
        return True

    if not run_tofu(['apply', '-target', 'module.connectivity', '-var-file=generated/terraform.tfvars', '-auto-approve'], "Deploying Connectivity"):
        return False
        
    return True

def phase_2b_connect_ssm(cluster_name: str, session: boto3.Session) -> bool:
    """Phase 2b: Configure Slurmrestd (SSM)."""
    console.print(Panel("[bold]Phase 2b: Head Node Configuration[/bold]", border_style="blue"))
    
    head_node_id = get_head_node_id(cluster_name, session)
    if not head_node_id: 
        console.print("[red]❌ Could not find Head Node Instance ID for SSM configuration.[/red]")
        return False

    # Quick SSM check - should already be ready after Phase 2a
    if not wait_for_ssm_ready(head_node_id, session, timeout=30):
        console.print("[yellow]⚠ SSM not ready yet, waiting 60s more...[/yellow]")
        time.sleep(60)
        if not wait_for_ssm_ready(head_node_id, session, timeout=30):
            console.print("[red]❌ SSM agent not registered. Check instance IAM role and network connectivity.[/red]")
            return False

    # Check if port 6830 is listening
    if not verify_slurmrestd(head_node_id, session):
        console.print("[dim]Configuring slurmrestd on head node...[/dim]")
        onboarding = get_tofu_output('clusterra_onboarding', as_json=True) or {}
        jwt_secret = onboarding.get('slurm_jwt_secret_arn')
        if not jwt_secret:
             console.print("[red]❌ Missing JWT Secret in Tofu output[/red]")
             return False
        
        run_ssm_script(head_node_id, "modules/cluster-connect/scripts/setup-slurmrestd.sh", [jwt_secret], session)
        if not verify_slurmrestd(head_node_id, session):
             console.print("[red]❌ Verified failed after setup[/red]")
             return False
    else:
        console.print("[green]✓ slurmrestd is listening[/green]")

    return True

def phase_4_register(cluster_name: str, region: str, tenant_id: str, api_url: str, dry_run: bool, session: boto3.Session) -> bool:
    """Phase 4: Register with Clusterra API."""
    console.print(Panel("[bold]Phase 4: Registration[/bold]", border_style="blue"))

    # Check if already registered (using explicit flag, not cluster_id presence)
    tfvars = Path("generated/terraform.tfvars").read_text()
    if 'registered = "true"' in tfvars:
        console.print("[green]✓ Already registered with Clusterra API[/green]")
        return True

    if dry_run:
        console.print("[yellow]Dry Run: Would call API to register[/yellow]")
        return True

    # Get cluster_id from tfvars (generated earlier in gather_inputs)
    cluster_id = None
    for line in tfvars.split('\n'):
        if line.strip().startswith('cluster_id'):
            # Parse: cluster_id = "clus1234"
            cluster_id = line.split('=')[1].strip().strip('"')
            break
    
    if not cluster_id:
        console.print("[red]❌ cluster_id not found in tfvars[/red]")
        return False

    onboarding = get_tofu_output('clusterra_onboarding', as_json=True) or {}

    if not onboarding.get('lattice_service_endpoint'):
         console.print("[red]❌ Missing Lattice Endpoint. Did Phase 2a finish?[/red]")
         return False

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

    # Generate STS token for AWS account verification
    sts_token = generate_sts_token(session)
    
    url = f"{api_url}/v1/internal/connect/{tenant_id}"
    console.print(f"[cyan]→ POST {url}[/cyan]")
    
    # 1st Attempt: Register cluster (also triggers RAM share principal addition)
    try:
        resp = requests.post(url, json=payload, headers={"X-AWS-STS-Token": sts_token}, timeout=30)
    except requests.exceptions.Timeout:
        console.print("[yellow]⚠ Request timed out (Expected if RAM share is pending...)[/yellow]")
        resp = None
    except Exception as e:
        console.print(f"[red]❌ API Error: {e}[/red]")
        return False

    first_success = resp and resp.status_code == 201
    if first_success:
        console.print(f"[green]✓ Cluster registered![/green]")

    # ALWAYS check for RAM invitation (blocking wait)
    # This enables the Lattice service-to-network association
    console.print("[dim]Waiting for RAM Resource Share invitation...[/dim]")
    if not wait_for_ram_acceptance(session):
        console.print("[red]❌ Failed to accept RAM invitation. Cannot proceed with Lattice association.[/red]")
        return False
    
    # Perform Lattice Association locally
    service_arn = onboarding.get("lattice_service_arn", "")
    network_id = onboarding.get("lattice_service_network_id", "")
    
    if not service_arn or not network_id:
        console.print("[red]❌ Missing Lattice Service ARN or Network ID. Check Tofu outputs.[/red]")
        return False

    if not associate_lattice_service(session, service_arn, network_id):
        return False

    update_tfvars({'registered': 'true'})
    console.print(f"[green]✓ Registration complete! Cluster ID: {cluster_id}[/green]")
    return True


CLUSTERRA_SERVICE_NETWORK_NAME = "clusterra-service-network"

def accept_ram_invitation(session: boto3.Session) -> bool:
    """Check for and accept the Clusterra service network RAM invitation.
    
    Returns True if the invitation is accepted OR already accepted (can proceed).
    Returns False if no invitation found yet (caller should retry).
    """
    ram = session.client('ram')
    try:
        resp = ram.get_resource_share_invitations()
        invites = resp.get('resourceShareInvitations', [])
        
        # Find our specific service network invitation
        for invite in invites:
            name = invite.get('resourceShareName', '')
            if CLUSTERRA_SERVICE_NETWORK_NAME not in name:
                continue  # Not our invitation
            
            status = invite.get('status')
            arn = invite['resourceShareInvitationArn']
            sender = invite['senderAccountId']
            
            if status == 'ACCEPTED':
                console.print(f"[green]✓ RAM invitation for '{name}' already accepted[/green]")
                return True
            
            if status == 'PENDING':
                console.print(f"[yellow]⚡ Found RAM Invitation for '{name}' from {sender}[/yellow]")
                console.print(f"[dim]Accepting {arn}...[/dim]")
                ram.accept_resource_share_invitation(resourceShareInvitationArn=arn)
                console.print(f"[green]✓ Accepted RAM invitation[/green]")
                time.sleep(5)  # Allow propagation
                return True
        
        # No matching invitation found
        return False
            
    except Exception as e:
        console.print(f"[red]⚠ Error checking RAM invitations: {e}[/red]")
        return False


def wait_for_ram_acceptance(session: boto3.Session, timeout: int = 300) -> bool:
    """Poll for RAM invitation and accept it."""
    elapsed = 0
    interval = 10
    
    with Progress(SpinnerColumn(), TextColumn("{task.description}"), TimeElapsedColumn(), console=console) as progress:
        task = progress.add_task("Waiting for RAM Invitation...", total=None)
        
        while elapsed < timeout:
            if accept_ram_invitation(session):
                return True
                
            time.sleep(interval)
            elapsed += interval
            progress.update(task, description=f"Waiting for RAM Invitation... ({elapsed}s)")
            
    return False


def associate_lattice_service(session: boto3.Session, service_arn: str, service_network_id: str) -> bool:
    """Associate the local Lattice Service with the Clusterra Service Network."""
    lattice = session.client('vpc-lattice')
    console.print(f"[dim]Associating service {service_arn} with network {service_network_id}...[/dim]")
    try:
        lattice.create_service_network_service_association(
            serviceNetworkIdentifier=service_network_id,
            serviceIdentifier=service_arn
        )
        console.print("[green]✓ Service associated with Clusterra Service Network[/green]")
        return True
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code')
        if error_code == 'ConflictException':
            console.print("[green]✓ Service already associated[/green]")
            return True
        console.print(f"[red]❌ Association failed: {e}[/red]")
        return False
    except Exception as e:
        console.print(f"[red]❌ Association failed: {e}[/red]")
        return False


def generate_sts_token(session: boto3.Session) -> str:
    """
    Generate presigned STS GetCallerIdentity token for AWS account verification.
    The server executes this presigned request to verify we own the AWS account.
    """
    import base64
    import json
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
    
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


def phase_3a_events_infra(dry_run: bool) -> bool:
    """Phase 3a: Events Infrastructure (Tofu)."""
    console.print(Panel("[bold]Phase 3a: Events Infrastructure[/bold]", border_style="blue"))
    
    if dry_run: return True
    return run_tofu(['apply', '-target', 'module.events', '-var-file=generated/terraform.tfvars', '-auto-approve'], "Deploying Events Infra")

def phase_3b_events_hooks(cluster_name: str, session: boto3.Session, dry_run: bool) -> bool:
    """Phase 3b: Event Hooks (SSM)."""
    console.print(Panel("[bold]Phase 3b: Event Hooks[/bold]", border_style="blue"))

    if dry_run: return True

    sqs_url = get_tofu_output('events_sqs_url')
    if not sqs_url:
        console.print("[red]❌ No SQS URL found. Did Phase 3a finish?[/red]")
        return False
        
    head_node_id = get_head_node_id(cluster_name, session)
    
    # Check if hooks already installed? (Hard to check without logging in, just idempotent run)
    args = [sqs_url]
    
    # Upload entire hooks directory and run install-hooks.sh
    return run_ssm_script_package(head_node_id, "modules/cluster-events/hooks", "install-hooks.sh", args, session)

# ─────────────────────────────────────────────────────────────────────────────
# UTILS
# ─────────────────────────────────────────────────────────────────────────────

def update_tfvars(updates: dict):
    path = Path("generated/terraform.tfvars")
    if not path.exists(): path.write_text("")
    content = path.read_text()
    
    with path.open('a') as f:
        for k, v in updates.items():
            if f'{k} =' not in content:
                f.write(f'\n{k} = "{v}"')

def verify_slurmrestd(instance_id: str, session: boto3.Session) -> bool:
    """Check if port 6830 is open via SSM."""
    cmd = "sudo ss -tlnp | grep 6830"
    success, res = send_ssm_command(instance_id, [cmd], session)
    return success and res and "6830" in res

def run_ssm_script(instance_id: str, script_rel_path: str, args: list, session: boto3.Session) -> bool:
    """Read a local script and run it on instance via SSM using base64 encoding."""
    import base64
    
    path = Path.cwd() / script_rel_path
    if not path.exists():
        console.print(f"[red]❌ Script not found: {path}[/red]")
        return False
    
    content = path.read_text()
    # Base64 encode the script to avoid heredoc/escaping issues
    encoded = base64.b64encode(content.encode()).decode()
    arg_str = " ".join([f"'{a}'" for a in args])
    
    # Single command that decodes and runs the script
    commands = [
        f"echo '{encoded}' | base64 -d > /tmp/script.sh && chmod +x /tmp/script.sh && sudo bash /tmp/script.sh {arg_str}"
    ]
    
    console.print(f"[dim]Running {path.name} on {instance_id}...[/dim]")
    success, output = send_ssm_command(instance_id, commands, session)
    if success:
        console.print(f"[green]✓ Script executed successfully[/green]")
        if output and output.strip():
            console.print(f"[dim]{output[:500]}[/dim]")  # Show first 500 chars
        return True
    else:
        console.print(f"[red]❌ Script execution failed[/red]")
        if output:
            console.print(f"[red]{output}[/red]")
        return False

def run_ssm_script_package(instance_id: str, folder_rel_path: str, main_script_name: str, args: list, session: boto3.Session) -> bool:
    """Bundle a folder and run a script from it on the instance."""
    import base64
    import tarfile
    import io

    path = Path.cwd() / folder_rel_path
    if not path.exists():
        console.print(f"[red]❌ Script folder not found: {path}[/red]")
        return False

    # Create tar.gz in memory
    file_obj = io.BytesIO()
    with tarfile.open(fileobj=file_obj, mode="w:gz") as tar:
        # ARCNAME is important: we want files to be roughly at root of tar or inside a dir?
        # Let's put them inside a dir named after folder
        tar.add(path, arcname=path.name)
    
    file_obj.seek(0)
    encoded = base64.b64encode(file_obj.read()).decode()
    
    arg_str = " ".join([f"'{a}'" for a in args])
    # The tar will unpack into its own directory name (path.name)
    remote_src_dir = f"/tmp/{path.name}"
    
    # Command to:
    # 1. Clean old dir
    # 2. Decode and untar
    # 3. Exec main script
    commands = [
        f"rm -rf {remote_src_dir}",
        f"cd /tmp && echo '{encoded}' | base64 -d | tar -xz",
        f"chmod +x {remote_src_dir}/*",
        f"sudo bash {remote_src_dir}/{main_script_name} {arg_str}"
    ]
    
    console.print(f"[dim]Deploying package {path.name} to {instance_id}...[/dim]")
    success, output = send_ssm_command(instance_id, commands, session)
    
    if success:
        console.print(f"[green]✓ Package executed successfully[/green]")
        if output and output.strip():
            console.print(f"[dim]{output[:500]}[/dim]")
        return True
    else:
        console.print(f"[red]❌ Package execution failed[/red]")
        if output:
            console.print(f"[red]{output}[/red]")
        return False

def send_ssm_command(instance_id: str, commands: list, session: boto3.Session) -> tuple[bool, str | None]:
    ssm = session.client('ssm')
    retries = 3
    for attempt in range(retries):
        try:
            resp = ssm.send_command(
                InstanceIds=[instance_id],
                DocumentName="AWS-RunShellScript",
                Parameters={'commands': commands}
            )
            cmd_id = resp['Command']['CommandId']
            
            # Wait
            time.sleep(2)
            for _ in range(30): # 60s timeout
                inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
                if inv['Status'] == 'Success':
                    return True, inv['StandardOutputContent']
                elif inv['Status'] in ['Failed', 'Cancelled', 'TimedOut']:
                    if attempt < retries - 1: break # Retry command
                    return False, inv.get('StandardErrorContent', '') or "Command failed"
                time.sleep(2)
            if attempt == retries - 1:
                return False, "Timed out waiting for execution"
            
        except Exception as e:
            msg = str(e)
            if "InvalidInstanceId" in msg and attempt < retries - 1:
                console.print(f"[dim]SSM Agent not ready, retrying ({attempt+1}/{retries})...[/dim]")
                time.sleep(10)
                continue
            console.print(f"[yellow]SSM Error: {e}[/yellow]")
            return False, str(e)
    return False, "Max retries exceeded"

def ensure_ssm_permissions(instance_id: str, session: boto3.Session):
    """Ensure instance has AmazonSSMManagedInstanceCore policy."""
    ec2 = session.client('ec2')
    iam = session.client('iam')
    
    try:
        # Get IAM role from instance profile
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        if not resp['Reservations']: return
        
        instance = resp['Reservations'][0]['Instances'][0]
        if 'IamInstanceProfile' not in instance:
            console.print("[yellow]⚠ No IAM Instance Profile found on head node. Cannot attach SSM policy.[/yellow]")
            return

        profile_arn = instance['IamInstanceProfile']['Arn']
        profile_name = profile_arn.split('/')[-1]
        
        # Get Role from Profile
        profile_resp = iam.get_instance_profile(InstanceProfileName=profile_name)
        roles = profile_resp['InstanceProfile']['Roles']
        if not roles: return
        
        role_name = roles[0]['RoleName']
        
        # Attach Policy
        policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        console.print(f"[dim]Ensuring SSM policy on role {role_name}...[/dim]")
        iam.attach_role_policy(RoleName=role_name, PolicyArn=policy_arn)
        
    except Exception as e:
        console.print(f"[yellow]⚠ Failed to check/attach SSM policy: {e}[/yellow]")


def wait_for_ssm_ready(instance_id: str, session: boto3.Session, timeout: int = 30) -> bool:
    """Wait for SSM agent to register with the service."""
    ssm = session.client('ssm')
    elapsed = 0
    interval = 5
    
    while elapsed < timeout:
        try:
            response = ssm.describe_instance_information(
                Filters=[{'Key': 'InstanceIds', 'Values': [instance_id]}]
            )
            if response.get('InstanceInformationList'):
                info = response['InstanceInformationList'][0]
                if info.get('PingStatus') == 'Online':
                    console.print(f"[green]✓ SSM agent is online[/green]")
                    return True
        except Exception:
            pass
        time.sleep(interval)
        elapsed += interval
    
    return False


def gather_inputs(session: boto3.Session):
    """Interactive input gathering with validation."""
    
    # Load existing vars if any
    existing_vars = {}
    if Path("generated/terraform.tfvars").exists():
        import re
        content = Path("generated/terraform.tfvars").read_text()
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith('#'): continue
            match = re.match(r'(\w+)\s*=\s*"?([^"]*)"?', line)
            if match:
                existing_vars[match.group(1)] = match.group(2)

    # Validator
    validate_required = lambda val: len(val.strip()) > 0 or "This field is required"
    validate_cluster_id = lambda val: (len(val.strip()) == 8 and val.startswith("clus")) or "Must be 8 chars starting with 'clus' (e.g., clusa1b2)"

    # 1. Scenario Selection
    console.print()
    scenario = questionary.select(
        "What would you like to do?",
        choices=[
            questionary.Choice("🆕 New Cluster - Deploy fresh ParallelCluster + connect to Clusterra", value="new"),
            questionary.Choice("🔗 Existing Cluster - Connect existing ParallelCluster to Clusterra", value="existing"),
            questionary.Choice("🔄 Update - Update an existing Clusterra-connected cluster", value="update"),
        ],
        style=PROMPT_STYLE
    ).ask()
    
    if not scenario: sys.exit(0)

    # For update scenario, ask for existing cluster_id upfront
    cluster_id = ""
    if scenario == "update":
        cluster_id = questionary.text(
            "Existing Cluster ID (e.g., clusa1b2):", 
            style=PROMPT_STYLE, 
            validate=validate_cluster_id
        ).ask()
        if cluster_id is None: sys.exit(0)

    # 2. Region (Confirm or Change)
    current_region = existing_vars.get('region') or session.region_name or 'ap-south-1'
    region = questionary.text("AWS Region:", default=current_region, style=PROMPT_STYLE, validate=validate_required).ask()
    if region is None: sys.exit(0)

    # Re-init session if region changed
    if region != session.region_name:
        session = boto3.Session(region_name=region)

    # 3. Cluster Name, ID, & Tenant ID (Hoisted)
    
    # Generate cluster_id early if needed
    if scenario in ["new", "existing"]:
        import uuid
        # Check if we have one already
        existing_cid = existing_vars.get('cluster_id')
        if existing_cid:
            cluster_id = existing_cid
        else:
            cluster_id = f"clus{uuid.uuid4().hex[:4]}"
            console.print(f"[cyan]Generated cluster ID: {cluster_id}[/cyan]")
    else:
        # Update scenario handled above
        pass

    # Default name with suffix
    default_base = existing_vars.get('cluster_name', f'clusterra-{cluster_id}' if 'cluster_id' in locals() else 'clusterra')
    
    cluster_name = questionary.text("Cluster Name:", default=default_base, style=PROMPT_STYLE, validate=validate_required).ask()
    if cluster_name is None: sys.exit(0)

    # 4. Scenario Specifics
    vpc_id = ""
    subnet_id = ""
    head_node_id = ""
    secondary_subnet_id = existing_vars.get('secondary_subnet_id', '')  # May not be needed for existing clusters
    
    if scenario == "existing":
        # Ask for Head Node ID to auto-detect VPC/Subnet
        default_head = existing_vars.get('head_node_instance_id', '')
        
        # Enforce valid Head Node ID
        while True:
            head_node_id = questionary.text("Head Node Instance ID (i-...):", default=default_head, style=PROMPT_STYLE, validate=validate_required).ask()
            if not head_node_id: sys.exit(0) # User cancelled
            
            # Verify Head Node and get VPC/Subnet
            ec2 = session.client('ec2')
            try:
                console.print(f"[dim]Verifying instance {head_node_id}...[/dim]")
                resp = ec2.describe_instances(InstanceIds=[head_node_id])
                inst = resp['Reservations'][0]['Instances'][0]
                vpc_id = inst['VpcId']
                subnet_id = inst['SubnetId']
                
                # Check state
                state = inst.get('State', {}).get('Name')
                if state not in ['running', 'pending']:
                     console.print(f"[yellow]⚠ Instance is {state}, but continuing...[/yellow]")
                
                console.print(f"[green]✓ Found instance in {vpc_id} / {subnet_id}[/green]")
                break # Valid!
            except Exception:
                console.print(f"[red]❌ Could not find instance {head_node_id} in {region}[/red]")
                if not questionary.confirm("Try again?", default=True).ask():
                    sys.exit(1)
                default_head = "" # Clear default on retry

    else: # NEW Cluster
        # VPC Selection
        vpcs = list_vpcs(session)
        vpc_choices = [questionary.Choice(f"{v['id']} ({v['name']})", value=v['id']) for v in vpcs]
        if vpc_choices:
            default_vpc = existing_vars.get('vpc_id')
            if default_vpc and not any(c.value == default_vpc for c in vpc_choices):
                 default_vpc = None 
            vpc_id = questionary.select("Select VPC:", choices=vpc_choices, default=default_vpc, style=PROMPT_STYLE).ask()
            if vpc_id is None: sys.exit(0)
        else:
            vpc_id = questionary.text("VPC ID:", default=existing_vars.get('vpc_id', ''), style=PROMPT_STYLE, validate=validate_required).ask()
            if vpc_id is None: sys.exit(0)

        # Subnet Selection using Boto3 (Validation!)
        subnets = list_subnets(session, vpc_id)
        if not subnets:
            console.print(f"[red]❌ No subnets found in {vpc_id}[/red]")
            sys.exit(1)
            
        subnet_choices = [questionary.Choice(f"{s['id']} ({s['name']} - {s['az']})", value=s['id']) for s in subnets]
        default_subnet = existing_vars.get('subnet_id')
        if default_subnet and not any(c.value == default_subnet for c in subnet_choices):
             console.print(f"[yellow]⚠ Previous subnet {default_subnet} not found. Please select properly.[/yellow]")
             default_subnet = None

        subnet_id = questionary.select("Select Subnet (Public for Head Node):", choices=subnet_choices, default=default_subnet, style=PROMPT_STYLE).ask()
        if subnet_id is None: sys.exit(0)

        # Secondary Subnet Selection (for Aurora - Different AZ)
        selected_az = next((s['az'] for s in subnets if s['id'] == subnet_id), None)
        secondary_subnets = [s for s in subnets if s['az'] != selected_az]
        
        if not secondary_subnets:
             console.print(f"[red]❌ No subnets found in a different AZ than {selected_az}. Aurora requires at least 2 AZs.[/red]")
             sys.exit(1)

        secondary_choices = [questionary.Choice(f"{s['id']} ({s['name']} - {s['az']})", value=s['id']) for s in secondary_subnets]
        default_secondary = existing_vars.get('secondary_subnet_id')
        if default_secondary and not any(c.value == default_secondary for c in secondary_choices):
             default_secondary = None

        secondary_subnet_id = questionary.select(
            "Select Secondary Subnet (Different AZ for Aurora):", 
            choices=secondary_choices, 
            default=default_secondary, 
            style=PROMPT_STYLE
        ).ask()
        if secondary_subnet_id is None: sys.exit(0)

    console.print("[dim]Hint: Find your Tenant ID in the URL: https://console.clusterra.cloud/manage/[tenant_id] AND click 'Connect Cluster'.[/dim]")
    tenant_id = questionary.text("Tenant ID (ten_...):", default=existing_vars.get('tenant_id', ''), style=PROMPT_STYLE, validate=validate_required).ask()
    if tenant_id is None: sys.exit(0)
    
    # Ensure generated dir exists
    Path("generated").mkdir(exist_ok=True)
    
    # Write to tfvars
    with open("generated/terraform.tfvars", "w") as f:
        f.write(f'region = "{region}"\n')
        f.write(f'cluster_name = "{cluster_name}"\n')
        f.write(f'vpc_id = "{vpc_id}"\n')
        f.write(f'subnet_id = "{subnet_id}"\n')
        f.write(f'secondary_subnet_id = "{secondary_subnet_id}"\n')
        f.write(f'tenant_id = "{tenant_id}"\n')
        f.write(f'cluster_id = "{cluster_id}"\n')
        
        # New vs Existing/Update Logic
        if scenario == "new":
            f.write(f'deploy_new_cluster = true\n')
            # Ask for SSH Key for new clusters
            keys = list_ssh_keys(session)
            key = questionary.select("SSH Key:", choices=keys, style=PROMPT_STYLE).ask() if keys else questionary.text("SSH Key Name:", validate=validate_required).ask()
            if key is None: sys.exit(0)
            f.write(f'ssh_key_name = "{key}"\n')
        else:
            f.write(f'deploy_new_cluster = false\n')
            if head_node_id:
                f.write(f'head_node_instance_id = "{head_node_id}"\n')

        f.write(f'clusterra_service_network_id = "sn-0f72eeda2ea824169"\n')

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Clusterra Connect Installer")
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--profile')
    parser.add_argument('--region')
    args = parser.parse_args()

    if args.profile:
        os.environ["AWS_PROFILE"] = args.profile

    console.print(Panel.fit("[bold cyan]Clusterra Connect[/bold cyan]\n[dim]Tofu-Centric Installer[/dim]", border_style="cyan"))

    try:
        if not run_preflight_checks():
            sys.exit(1)

        session = get_aws_session(args.profile, args.region)
        gather_inputs(session) # Ensure tfvars exist

        # Load vars for params
        # Simple regex parser to avoid hcl dependency
        import re
        tfvars = {}
        if Path("generated/terraform.tfvars").exists():
            content = Path("generated/terraform.tfvars").read_text()
            for line in content.splitlines():
                line = line.strip()
                if not line or line.startswith('#'): continue
                match = re.search(r'(\w+)\s*=\s*"?([^"]*)"?', line)
                if match:
                    tfvars[match.group(1)] = match.group(2)
        
        cluster_name = tfvars.get('cluster_name', '')
        region = tfvars.get('region', '')
        tenant_id = tfvars.get('tenant_id', '')
        deploy_new = tfvars.get('deploy_new_cluster', 'true').lower() == 'true'
        
        # Execute Phases (Granular)
        if deploy_new:
            if not phase_1a_config(cluster_name, args.dry_run): return
            if not phase_1b_create(cluster_name, region, args.dry_run, session): return
        else:
            console.print("[dim]Skipping Phases 1a & 1b (Existing Cluster Mode)[/dim]")

        if not phase_2a_connect_infra(cluster_name, args.dry_run, session): return
        
        # Phase 2b: Configure SSM
        if not args.dry_run:
            if not phase_2b_connect_ssm(cluster_name, session): return

        # Phase 3: Events
        if not phase_3a_events_infra(args.dry_run): return
        if not phase_3b_events_hooks(cluster_name, session, args.dry_run): return
        
        # Phase 4: Registration
        if not phase_4_register(cluster_name, region, tenant_id, DEFAULT_API_URL, args.dry_run, session): return

        console.print(Panel("[bold green]✅ Deployment Complete![/bold green]"))

    except KeyboardInterrupt:
        console.print("\n[yellow]Setup cancelled by user.[/yellow]")
        sys.exit(0)

if __name__ == "__main__":
    main()
