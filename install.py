#!/usr/bin/env python3
"""
Clusterra Connect Interactive Installer

A staged deployment orchestrator that configures and deploys clusterra-connect
with AWS auto-detection, state persistence, and failure recovery.

Deployment Stages:
  1. INFRA: Create JWT secret, EFS, generate pcluster config (for new clusters)
  2. PCLUSTER: Run pcluster create-cluster and wait for completion
  3. CONNECT: Deploy NLB, VPC Endpoint Service, IAM Role
  4. REGISTER: Call Clusterra API to register cluster
  5. EVENTS: Deploy SQS, Lambda, CloudWatch Event Rules
"""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional

# Check for required dependencies
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
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.progress import Progress, SpinnerColumn, TextColumn, TimeElapsedColumn
except ImportError:
    print("❌ rich is required. Install with: pip install rich")
    sys.exit(1)

try:
    import requests
except ImportError:
    print("❌ requests is required. Install with: pip install requests")
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

def check_tool_installed(tool: str, install_hint: str) -> tuple[bool, str | None]:
    """Check if a CLI tool is installed and return version."""
    try:
        # 1. Check current PATH
        cmd = [tool, '--version'] if tool in ['aws', 'node'] else [tool, 'version']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        if result.returncode == 0:
            output = result.stdout.strip() or result.stderr.strip()
            # Handle JSON output (common in pcluster)
            if output.startswith('{'):
                try:
                    import json
                    data = json.loads(output)
                    return True, data.get('version', 'unknown')
                except json.JSONDecodeError:
                    pass
            
            return True, output.split('\n')[0]
            
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
        
    # 2. If not found, look in common locations and update PATH if found
    common_paths = [
        Path.home() / ".local/bin",                  # User local bin
        Path("/opt/homebrew/bin"),                   # Homebrew Apple Silicon
        Path("/usr/local/bin"),                      # Homebrew Intel / System
    ]
    
    # Add Python user scripts dir
    try:
        import sysconfig
        scripts_path = Path(sysconfig.get_path("scripts"))
        if scripts_path not in common_paths:
            common_paths.append(scripts_path)
        
        # Also check user site base
        import site
        user_base = Path(site.getuserbase()) / "bin"
        if user_base not in common_paths:
            common_paths.append(user_base)
            
        # Also check Library/Python (common on macOS)
        lib_python = Path.home() / "Library/Python"
        if lib_python.exists():
            for ver_dir in lib_python.glob("*/bin"):
                common_paths.append(ver_dir)
                
    except ImportError:
        pass

    for search_path in common_paths:
        tool_path = search_path / tool
        if tool_path.exists() and os.access(tool_path, os.X_OK):
            # FOUND! Add to PATH for this process
            current_path = os.environ.get("PATH", "")
            if str(search_path) not in current_path.split(os.pathsep):
                os.environ["PATH"] = f"{search_path}{os.pathsep}{current_path}"
            
            # Re-check to get version
            try:
                cmd = [tool, '--version'] if tool in ['aws', 'node'] else [tool, 'version']
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    output = result.stdout.strip() or result.stderr.strip()
                    version_str = output.split('\n')[0]
                    
                    if output.startswith('{'):
                        try:
                            import json
                            data = json.loads(output)
                            version_str = data.get('version', 'unknown')
                        except json.JSONDecodeError:
                            pass
                            
                    return True, f"{version_str} (in {search_path})"
            except Exception:
                pass
                
    return False, install_hint


def run_preflight_checks(scenario: str = "new") -> bool:
    """
    Run pre-flight checks for required CLI tools.
    Returns True if all checks pass, False otherwise.
    """
    from rich.console import Console
    console = Console()
    
    checks = [
        ('aws', 'pip install awscli  OR  brew install awscli'),
        ('tofu', 'brew install opentofu  OR  https://opentofu.org/docs/intro/install/'),
    ]
    
    # pcluster and node are only required for new cluster deployments
    if scenario == "new":
        checks.append(('node', 'brew install node  OR  https://nodejs.org/'))
        checks.append(('pcluster', 'pip install aws-parallelcluster'))
    
    all_passed = True
    console.print("[bold]Pre-flight Checks[/bold]")
    console.print()
    
    for tool, hint in checks:
        installed, info = check_tool_installed(tool, hint)
        if installed:
            console.print(f"  [green]✓[/green] {tool}: [dim]{info}[/dim]")
        else:
            console.print(f"  [red]✗[/red] {tool}: [red]not found[/red]")
            console.print(f"    [dim]Install: {hint}[/dim]")
            all_passed = False
    
    console.print()
    
    if not all_passed:
        console.print("[red]❌ Please install missing tools and try again.[/red]")
        console.print("[dim]Note: If installed, ensure they are in your PATH or common locations like /opt/homebrew/bin[/dim]")
    
    return all_passed


# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

CLUSTERRA_AWS_ACCOUNT_ID = "306847926740"  # Clusterra's AWS account
STATE_FILE = ".clusterra-state.json"
DEFAULT_API_URL = "https://api.clusterra.cloud"


# ─────────────────────────────────────────────────────────────────────────────
# STYLING
# ─────────────────────────────────────────────────────────────────────────────

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
# DEPLOYMENT STATE MACHINE
# ─────────────────────────────────────────────────────────────────────────────

class DeploymentStage(str, Enum):
    """Deployment stages - ordered for sequential execution.
    
    Naming convention:
    - 1x: Cluster Create (parallelcluster module)
    - 2x: Cluster Connect (connectivity module)
    - 3x: API Registration
    - 4x: Events Setup (events module)
    """
    NOT_STARTED = "not_started"
    # Cluster Create stages
    STAGE_1A_GENERATE_CONFIG = "1a_generate_config"
    STAGE_1B_PCLUSTER_PENDING = "1b_pcluster_pending"
    STAGE_1C_PCLUSTER_COMPLETE = "1c_pcluster_complete"
    # Cluster Connect stages
    STAGE_2A_CONNECTIVITY = "2a_connectivity"
    STAGE_2B_CONFIGURE_SLURMRESTD = "2b_configure_slurmrestd"
    STAGE_2C_VERIFY_SLURMRESTD = "2c_verify_slurmrestd"
    # Events Setup (before registration so we can include event infra details)
    STAGE_3A_EVENTS = "3a_events"
    # API Registration (after events so we can include all infra details)
    STAGE_4A_REGISTER = "4a_register"
    COMPLETE = "complete"
    FAILED = "failed"


@dataclass
class DeploymentState:
    """Persistent deployment state."""
    version: int = 1
    stage: DeploymentStage = DeploymentStage.NOT_STARTED
    scenario: str = ""  # "new" or "existing"
    cluster_name: str = ""
    region: str = ""
    vpc_id: str = ""
    subnet_id: str = ""
    tenant_id: str = ""
    cluster_id: str = ""
    
    # Stage 1 outputs
    pcluster_config_path: str = ""
    slurm_jwt_secret_arn: str = ""
    
    # Stage 2 outputs
    head_node_instance_id: str = ""
    
    # Stage 3 outputs
    lattice_service_endpoint: str = ""
    lattice_service_network_id: str = ""
    iam_role_arn: str = ""
    iam_external_id: str = ""
    
    # Metadata
    created_at: str = ""
    updated_at: str = ""
    error_message: str = ""
    
    def to_dict(self) -> dict:
        d = asdict(self)
        d['stage'] = self.stage.value
        return d
    
    @classmethod
    def from_dict(cls, d: dict) -> 'DeploymentState':
        # Migration map for old stage names -> new stage names
        stage_migration = {
            'stage_1_infra': '1a_generate_config',
            'stage_2_pcluster_pending': '1b_pcluster_pending',
            'stage_2_pcluster_complete': '1c_pcluster_complete',
            'stage_3_connect': '2a_connectivity',
            'stage_3_configure_slurmrestd': '2b_configure_slurmrestd',
            'stage_3_verify_slurmrestd': '2c_verify_slurmrestd',
            'stage_4_register': '4a_register',  # Note: register is now 4a
            'stage_5_events': '3a_events',       # Note: events is now 3a
        }
        
        raw_stage = d.get('stage', 'not_started')
        # Apply migration if needed
        migrated_stage = stage_migration.get(raw_stage, raw_stage)
        d['stage'] = DeploymentStage(migrated_stage)
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


class StateManager:
    """Manages persistent deployment state."""
    
    def __init__(self, state_file: Path):
        self.state_file = state_file
        self.state = self._load()
    
    def _load(self) -> DeploymentState:
        if self.state_file.exists():
            try:
                data = json.loads(self.state_file.read_text())
                return DeploymentState.from_dict(data)
            except (json.JSONDecodeError, KeyError):
                pass
        return DeploymentState(created_at=datetime.utcnow().isoformat())
    
    def save(self):
        self.state.updated_at = datetime.utcnow().isoformat()
        self.state_file.write_text(json.dumps(self.state.to_dict(), indent=2))
    
    def update(self, **kwargs):
        for k, v in kwargs.items():
            if hasattr(self.state, k):
                setattr(self.state, k, v)
        self.save()
    
    def set_stage(self, stage: DeploymentStage):
        self.state.stage = stage
        self.save()
    
    def set_failed(self, error: str):
        self.state.error_message = error
        self.state.stage = DeploymentStage.FAILED
        self.save()
    
    def clear(self):
        self.state_file.unlink(missing_ok=True)
        self.state = DeploymentState(created_at=datetime.utcnow().isoformat())


# ─────────────────────────────────────────────────────────────────────────────
# AWS HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def get_aws_session(profile: str | None = None, region: str | None = None) -> boto3.Session:
    try:
        return boto3.Session(profile_name=profile, region_name=region)
    except ProfileNotFound:
        console.print(f"[red]❌ AWS profile '{profile}' not found[/red]")
        sys.exit(1)


def detect_region(session: boto3.Session) -> str | None:
    return session.region_name or os.environ.get('AWS_DEFAULT_REGION')


def list_vpcs(session: boto3.Session) -> list[dict]:
    ec2 = session.client('ec2')
    try:
        response = ec2.describe_vpcs()
        return [{
            'id': v['VpcId'],
            'name': next((t['Value'] for t in v.get('Tags', []) if t['Key'] == 'Name'), 'unnamed'),
            'cidr': v['CidrBlock'],
            'is_default': v.get('IsDefault', False),
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


def get_pcluster_status(cluster_name: str, region: str) -> dict | None:
    """Get ParallelCluster status via CLI."""
    try:
        result = subprocess.run(
            ['pcluster', 'describe-cluster', '--cluster-name', cluster_name, '--region', region],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        pass
    return None


def get_pcluster_status_via_boto3(cluster_name: str, session: boto3.Session) -> dict | None:
    """Get ParallelCluster status via CloudFormation (fallback when pcluster CLI unavailable)."""
    try:
        cfn = session.client('cloudformation')
        response = cfn.describe_stacks(StackName=cluster_name)
        
        if not response['Stacks']:
            return None
        
        stack = response['Stacks'][0]
        stack_status = stack['StackStatus']
        
        # Map CloudFormation status to pcluster status
        cluster_status = 'UNKNOWN'
        if 'CREATE_COMPLETE' in stack_status:
            cluster_status = 'CREATE_COMPLETE'
        elif 'CREATE_IN_PROGRESS' in stack_status:
            cluster_status = 'CREATE_IN_PROGRESS'
        elif 'CREATE_FAILED' in stack_status:
            cluster_status = 'CREATE_FAILED'
        
        # Try to find head node instance ID from stack resources
        head_node_id = None
        try:
            resources_response = cfn.describe_stack_resources(StackName=cluster_name)
            for resource in resources_response['StackResources']:
                if resource['LogicalResourceId'] == 'HeadNode':
                    head_node_id = resource.get('PhysicalResourceId')
                    break
        except Exception:
            pass
        
        return {
            'clusterStatus': cluster_status,
            'headNode': {'instanceId': head_node_id} if head_node_id else {}
        }
    except ClientError:
        return None


def get_head_node_instance_id(cluster_name: str, region: str) -> str | None:
    """Extract head node instance ID from pcluster describe-cluster."""
    status = get_pcluster_status(cluster_name, region)
    if status and status.get('clusterStatus') == 'CREATE_COMPLETE':
        return status.get('headNode', {}).get('instanceId')
    return None


# ─────────────────────────────────────────────────────────────────────────────
# TOFU COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

def run_tofu_apply(target_module: str | None = None, var_overrides: dict | None = None) -> bool:
    """Run tofu apply with optional module targeting."""
    cmd = ['tofu', 'apply', '-auto-approve']
    
    if target_module:
        cmd.extend(['-target', f'module.{target_module}'])
    
    if var_overrides:
        for k, v in var_overrides.items():
            cmd.extend(['-var', f'{k}={v}'])
    
    console.print(f"[cyan]→ {' '.join(cmd)}[/cyan]")
    result = subprocess.run(cmd, cwd=Path.cwd())
    return result.returncode == 0


def run_tofu_init() -> bool:
    """Run tofu init."""
    console.print("[cyan]→ tofu init[/cyan]")
    result = subprocess.run(['tofu', 'init'], cwd=Path.cwd())
    return result.returncode == 0


def get_tofu_output(name: str) -> str | None:
    """Get a specific tofu output value."""
    try:
        result = subprocess.run(
            ['tofu', 'output', '-raw', name],
            capture_output=True, text=True, cwd=Path.cwd()
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None


def get_tofu_outputs() -> dict:
    """Get all tofu outputs as JSON."""
    try:
        result = subprocess.run(
            ['tofu', 'output', '-json'],
            capture_output=True, text=True, cwd=Path.cwd()
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception:
        pass
    return {}


# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM VARS GENERATION
# ─────────────────────────────────────────────────────────────────────────────

def generate_tfvars(state: DeploymentState, ssh_key: str = "", instance_types: dict = None) -> str:
    """Generate terraform.tfvars from state."""
    lines = [
        "# Generated by Clusterra Connect Installer",
        f"# Stage: {state.stage.value}",
        "",
        f'region       = "{state.region}"',
        f'cluster_name = "{state.cluster_name}"',
        f'vpc_id       = "{state.vpc_id}"',
        f'subnet_id    = "{state.subnet_id}"',
        "",
    ]
    
    if state.scenario == "new":
        instance_types = instance_types or {}
        lines.extend([
            "# New cluster settings",
            "deploy_new_cluster      = true",
            f'ssh_key_name            = "{ssh_key}"',
            f'head_node_instance_type = "{instance_types.get("head", "t3.medium")}"',
            f'compute_instance_type   = "{instance_types.get("compute", "c5.xlarge")}"',
            "min_count               = 0",
            "max_count               = 10",
            "",
        ])
    else:
        lines.extend([
            "# Existing cluster settings",
            "deploy_new_cluster = false",
            "",
        ])
    
    if state.head_node_instance_id:
        lines.append(f'head_node_instance_id = "{state.head_node_instance_id}"')
    
    if state.tenant_id:
        lines.append(f'tenant_id = "{state.tenant_id}"')
    
    if state.cluster_id:
        lines.append(f'cluster_id = "{state.cluster_id}"')
    
    return '\n'.join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# DEPLOYMENT ORCHESTRATOR
# ─────────────────────────────────────────────────────────────────────────────

class Orchestrator:
    """Manages staged deployment execution."""
    
    def __init__(self, state_mgr: StateManager, session: boto3.Session, api_url: str):
        self.state_mgr = state_mgr
        self.session = session
        self.api_url = api_url
    
    @property
    def state(self) -> DeploymentState:
        return self.state_mgr.state
    
    def run(self, dry_run: bool = False) -> bool:
        """Execute deployment from current stage."""
        stage = self.state.stage
        
        try:
            # Route to appropriate stage handler
            if stage == DeploymentStage.NOT_STARTED:
                return self._run_stage_1(dry_run)
            elif stage == DeploymentStage.STAGE_1A_GENERATE_CONFIG:
                return self._run_stage_1(dry_run)
            elif stage == DeploymentStage.STAGE_1B_PCLUSTER_PENDING:
                return self._run_stage_2_create()  # Create (or check existing) then wait
            elif stage == DeploymentStage.STAGE_1C_PCLUSTER_COMPLETE:
                return self._run_stage_3_connect(dry_run)
            elif stage == DeploymentStage.STAGE_2A_CONNECTIVITY:
                return self._run_stage_3_connect(dry_run)
            elif stage == DeploymentStage.STAGE_2B_CONFIGURE_SLURMRESTD:
                return self._run_stage_3_configure(dry_run)
            elif stage == DeploymentStage.STAGE_2C_VERIFY_SLURMRESTD:
                return self._run_stage_3_verify(dry_run)
            elif stage == DeploymentStage.STAGE_3A_EVENTS:
                return self._run_stage_events(dry_run)
            elif stage == DeploymentStage.STAGE_4A_REGISTER:
                return self._run_stage_register(dry_run)
            elif stage == DeploymentStage.COMPLETE:
                console.print("[green]✓ Deployment already complete![/green]")
                return True
            elif stage == DeploymentStage.FAILED:
                console.print(f"[red]Previous deployment failed: {self.state.error_message}[/red]")
                if questionary.confirm("Retry from last successful stage?", style=PROMPT_STYLE).ask():
                    # Find last successful stage and retry
                    return self._retry_from_last_good_stage(dry_run)
                return False
        except KeyboardInterrupt:
            console.print("\n[yellow]Interrupted. Run again to resume.[/yellow]")
            return False
        except Exception as e:
            self.state_mgr.set_failed(str(e))
            console.print(f"[red]❌ Deployment failed: {e}[/red]")
            return False
        
        return True
    
    def _run_stage_1(self, dry_run: bool) -> bool:
        """Stage 1: Initialize and generate pcluster config (for new clusters)."""
        
        if self.state.scenario == "new":
            console.print(Panel("[bold]Stage 1a: Generating Cluster Config[/bold]", border_style="blue"))
            
            if dry_run:
                console.print("[yellow]🔸 Dry run - would generate pcluster config[/yellow]")
                self.state_mgr.set_stage(DeploymentStage.STAGE_1B_PCLUSTER_PENDING)
                return True
            
            # Run tofu init (needed for provider setup)
            if not run_tofu_init():
                self.state_mgr.set_failed("tofu init failed")
                return False
            
            # Apply only the parallelcluster module to generate the config file
            # This is a lightweight operation - it only creates a local YAML file
            console.print("[dim]Generating ParallelCluster configuration...[/dim]")
            if not run_tofu_apply(target_module="parallelcluster"):
                self.state_mgr.set_failed("Failed to generate pcluster config")
                return False
            
            # Get the config path from outputs
            outputs = get_tofu_outputs()
            config_path = outputs.get('pcluster_config_path', {}).get('value')
            if config_path:
                self.state_mgr.update(pcluster_config_path=config_path)
                console.print(f"[green]✓[/green] Config generated: [cyan]{config_path}[/cyan]")
            else:
                # Fallback to expected path
                config_path = f"./generated/{self.state.cluster_name}-config.yaml"
                self.state_mgr.update(pcluster_config_path=config_path)
            
            self.state_mgr.set_stage(DeploymentStage.STAGE_1B_PCLUSTER_PENDING)
            return self._run_stage_2_create()
        else:
            # For existing cluster, skip directly to connectivity stage
            console.print(Panel("[bold]Stage 1a: Initializing[/bold]", border_style="blue"))
            
            if dry_run:
                console.print("[yellow]🔸 Dry run - would initialize[/yellow]")
                self.state_mgr.set_stage(DeploymentStage.STAGE_2A_CONNECTIVITY)
                return True
            
            # Run tofu init
            if not run_tofu_init():
                self.state_mgr.set_failed("tofu init failed")
                return False
            
            self.state_mgr.set_stage(DeploymentStage.STAGE_2A_CONNECTIVITY)
            return self._run_stage_3_connect(dry_run)
    
    def _run_stage_2_create(self) -> bool:
        """Stage 2: Create ParallelCluster via CLI."""
        console.print(Panel("[bold]Stage 1b: Creating Cluster[/bold]", border_style="blue"))
        
        config_path = self.state.pcluster_config_path
        if not config_path:
            console.print("[red]❌ No pcluster config path found[/red]")
            return False
        
        # First, check if cluster already exists (use boto3, not pcluster CLI)
        console.print(f"[dim]Checking if cluster already exists...[/dim]")
        existing_status = get_pcluster_status_via_boto3(self.state.cluster_name, self.session)
        
        if existing_status:
            cluster_status = existing_status.get('clusterStatus', 'UNKNOWN')
            console.print(f"[yellow]Cluster already exists with status: {cluster_status}[/yellow]")
            
            if cluster_status == 'CREATE_COMPLETE':
                console.print("[green]✓ Cluster already created, skipping to next stage[/green]")
                
                # CRITICAL: Save state transition FIRST (and don't try to fetch metadata)
                self.state_mgr.set_stage(DeploymentStage.STAGE_1C_PCLUSTER_COMPLETE)
                
                # Note: head_node_id will be fetched later when needed (via boto3, not pcluster CLI)
                return self._run_stage_3_connect(dry_run=False)
            elif cluster_status in ['CREATE_IN_PROGRESS', 'CREATING']:
                console.print("[yellow]Cluster creation already in progress, waiting...[/yellow]")
                return self._run_stage_2_wait()
            elif cluster_status == 'CREATE_FAILED':
                console.print("[red]❌ Cluster creation previously failed[/red]")
                console.print("[dim]You may need to delete the failed cluster and try again[/dim]")
                self.state_mgr.set_failed("Cluster creation previously failed")
                return False
        
        console.print(f"[dim]Config: {config_path}[/dim]")
        console.print(f"[cyan]→ pcluster create-cluster --cluster-name {self.state.cluster_name} ...[/cyan]")
        
        # Start pcluster create (async)
        cmd = [
            'pcluster', 'create-cluster',
            '--cluster-name', self.state.cluster_name,
            '--cluster-configuration', config_path,
            '--region', self.state.region,
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        # Debug output
        if result.stdout.strip():
            console.print(f"[dim]STDOUT: {result.stdout.strip()}[/dim]")
        if result.stderr.strip():
            console.print(f"[dim]STDERR: {result.stderr.strip()}[/dim]")
            
        if result.returncode != 0:
            # Check if already exists
            if "already exists" in result.stderr.lower():
                console.print("[yellow]Cluster already exists, checking status...[/yellow]")
            else:
                self.state_mgr.set_failed(f"pcluster create failed: {result.stderr}")
                return False
        
        return self._run_stage_2_wait()
    
    def _run_stage_2_wait(self) -> bool:
        """Wait for ParallelCluster to complete."""
        console.print("[dim]Waiting for cluster creation (this takes 15-30 minutes)...[/dim]")
        console.print()
        
        # Provide AWS Console link for tracking
        cf_url = f"https://{self.state.region}.console.aws.amazon.com/cloudformation/home?region={self.state.region}#/stacks"
        console.print(f"[cyan]📊 Track progress in AWS Console:[/cyan]")
        console.print(f"   [link={cf_url}]{cf_url}[/link]")
        console.print()
        
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            TimeElapsedColumn(),
            console=console,
        ) as progress:
            task = progress.add_task("Creating cluster...", total=None)
            
            while True:
                status = get_pcluster_status_via_boto3(self.state.cluster_name, self.session)
                
                if not status:
                    time.sleep(30)
                    continue
                
                cluster_status = status.get('clusterStatus', 'UNKNOWN')
                progress.update(task, description=f"Cluster status: {cluster_status}")
                
                if cluster_status == 'CREATE_COMPLETE':
                    console.print("[green]✓ Cluster created successfully![/green]")
                    
                    # CRITICAL: Save state transition FIRST (and don't try to fetch metadata that needs pcluster CLI)
                    self.state_mgr.set_stage(DeploymentStage.STAGE_1C_PCLUSTER_COMPLETE)
                    
                    # Note: head_node_id will be fetched later when needed (via boto3, not pcluster CLI)
                    return self._run_stage_3_connect(dry_run=False)
                
                elif cluster_status == 'CREATE_FAILED':
                    self.state_mgr.set_failed("ParallelCluster creation failed")
                    console.print("[red]❌ Cluster creation failed[/red]")
                    console.print("[dim]Check CloudFormation console for details[/dim]")
                    return False
                
                elif cluster_status in ['CREATE_IN_PROGRESS', 'CREATING']:
                    time.sleep(30)  # Poll every 30 seconds
                else:
                    console.print(f"[yellow]Unknown status: {cluster_status}[/yellow]")
                    time.sleep(30)
    
    def _run_stage_3_connect(self, dry_run: bool) -> bool:
        """Stage 3a: Deploy connectivity (NLB, VPC Endpoint, IAM)."""
        console.print(Panel("[bold]Stage 2a: Connectivity[/bold]", border_style="blue"))
        
        if dry_run:
            console.print("[yellow]🔸 Dry run - would deploy connectivity module[/yellow]")
            self.state_mgr.set_stage(DeploymentStage.STAGE_2B_CONFIGURE_SLURMRESTD)
            return True
        
        # Update tfvars with head_node_instance_id
        tfvars_path = Path.cwd() / 'terraform.tfvars'
        tfvars_content = tfvars_path.read_text() if tfvars_path.exists() else ""
        
        if self.state.head_node_instance_id and 'head_node_instance_id' not in tfvars_content:
            with tfvars_path.open('a') as f:
                f.write(f'\nhead_node_instance_id = "{self.state.head_node_instance_id}"\n')
        
        # Run tofu apply for connectivity module
        if not run_tofu_apply(target_module="connectivity"):
            self.state_mgr.set_failed("tofu apply (connectivity) failed")
            return False
        
        # Get outputs
        outputs = get_tofu_outputs()
        onboarding = outputs.get('clusterra_onboarding', {}).get('value', {})
        
        self.state_mgr.update(
            lattice_service_endpoint=onboarding.get('lattice_service_endpoint', ''),
            lattice_service_network_id=onboarding.get('lattice_service_network_id', ''),
            iam_role_arn=onboarding.get('role_arn', ''),
            iam_external_id=onboarding.get('external_id', ''),
        )
        
        self.state_mgr.set_stage(DeploymentStage.STAGE_2B_CONFIGURE_SLURMRESTD)
        return self._run_stage_3_configure(dry_run)

    def _run_stage_3_configure(self, dry_run: bool) -> bool:
        """Stage 3b: Configure slurmrestd on head node."""
        if dry_run:
            self.state_mgr.set_stage(DeploymentStage.STAGE_2C_VERIFY_SLURMRESTD)
            return True
            
        outputs = get_tofu_outputs()
        onboarding = outputs.get('clusterra_onboarding', {}).get('value', {})
        jwt_secret = onboarding.get('slurm_jwt_secret_arn')
        
        if jwt_secret and self.state.head_node_instance_id:
            if not self._run_ssm_setup(self.state.head_node_instance_id, jwt_secret):
                self.state_mgr.set_failed("slurmrestd configuration failed")
                return False
        
        self.state_mgr.set_stage(DeploymentStage.STAGE_2C_VERIFY_SLURMRESTD)
        return self._run_stage_3_verify(dry_run)

    def _run_stage_3_verify(self, dry_run: bool) -> bool:
        """Stage 3c: Verify slurmrestd is healthy."""
        if dry_run:
            self.state_mgr.set_stage(DeploymentStage.STAGE_3A_EVENTS)
            return True
            
        if self.state.head_node_instance_id:
            console.print("[dim]Verifying slurmrestd is listening on port 6830...[/dim]")
            
            # Simple check command
            cmd = "sudo ss -tlnp | grep 6830"
            
            ssm = self.session.client('ssm')
            try:
                response = ssm.send_command(
                    InstanceIds=[self.state.head_node_instance_id],
                    DocumentName="AWS-RunShellScript",
                    Parameters={'commands': [cmd]}
                )
                command_id = response['Command']['CommandId']
                
                # Wait for result
                time.sleep(2)
                for _ in range(5):
                    result = ssm.get_command_invocation(
                        CommandId=command_id, 
                        InstanceId=self.state.head_node_instance_id
                    )
                    status = result['Status']
                    
                    if status == 'Success':
                        output = result.get('StandardOutputContent', '')
                        if "6830" in output:
                            console.print("[green]✓ slurmrestd is healthy and listening[/green]")
                            self.state_mgr.set_stage(DeploymentStage.STAGE_3A_EVENTS)
                            return self._run_stage_events(dry_run)
                        else:
                            console.print("[red]❌ Port 6830 not listening[/red]")
                            # Don't fail hard, user might want to debug
                            if not questionary.confirm("Verification failed. Continue anyway?", default=False).ask():
                                return False
                            break
                    elif status in ['Failed', 'Cancelled', 'TimedOut']:
                        console.print(f"[red]❌ Verification command failed: {result.get('StandardErrorContent')}[/red]")
                        return False
                    
                    time.sleep(2)
            except Exception as e:
                console.print(f"[yellow]⚠ Verification skipped due to error: {e}[/yellow]")
        
        self.state_mgr.set_stage(DeploymentStage.STAGE_3A_EVENTS)
        return self._run_stage_events(dry_run)

    def _run_ssm_setup(self, instance_id: str, jwt_secret_arn: str) -> bool:
        """Run setup-slurmrestd.sh on head node via SSM."""
        console.print("[dim]Configuring slurmrestd on head node (via SSM)...[/dim]")
        
        script_path = Path.cwd() / "scripts" / "setup-slurmrestd.sh"
        if not script_path.exists():
            console.print(f"[red]❌ Script not found: {script_path}[/red]")
            return False
            
        script_content = script_path.read_text()
        
        ssm = self.session.client('ssm')
        try:
            response = ssm.send_command(
                InstanceIds=[instance_id],
                DocumentName="AWS-RunShellScript",
                Parameters={
                    'commands': [
                        "cat << 'EOF' > /tmp/setup-slurmrestd.sh",
                        script_content,
                        "EOF",
                        f"sudo bash /tmp/setup-slurmrestd.sh '{jwt_secret_arn}'"
                    ]
                }
            )
            command_id = response['Command']['CommandId']
            
            # Wait for completion
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                TimeElapsedColumn(),
                console=console,
            ) as progress:
                task = progress.add_task("Running setup script...", total=None)
                
                while True:
                    time.sleep(2)
                    result = ssm.get_command_invocation(
                        CommandId=command_id,
                        InstanceId=instance_id
                    )
                    status = result['Status']
                    
                    if status == 'Success':
                        console.print("[green]✓ slurmrestd configured successfully[/green]")
                        return True
                    elif status in ['Failed', 'Cancelled', 'TimedOut']:
                        console.print(f"[red]❌ SSM command failed:[/red]")
                        console.print(result.get('StandardErrorContent', 'Unknown error'))
                        return False
                    elif status not in ['Pending', 'InProgress']:
                        # Should not happen
                        return False
                
        except ClientError as e:
            console.print(f"[yellow]⚠ Could not run via SSM: {e}[/yellow]")
            console.print("[yellow]Please run this command manually on the head node:[/yellow]")
            console.print(f"sudo bash setup-slurmrestd.sh '{jwt_secret_arn}'")
            return questionary.confirm("Did you run the script manually?", default=False).ask()
    
    def _run_stage_register(self, dry_run: bool) -> bool:
        """Stage 4a: Register with Clusterra API (final stage)."""
        console.print(Panel("[bold]Stage 4a: API Registration[/bold]", border_style="blue"))
        
        if not self.state.tenant_id:
            console.print("[yellow]No tenant_id set, skipping API registration[/yellow]")
            self.state_mgr.set_stage(DeploymentStage.COMPLETE)
            console.print(Panel("[bold green]✅ Deployment Complete![/bold green]", border_style="green"))
            return True
        
        if dry_run:
            console.print("[yellow]🔸 Dry run - would call API to register[/yellow]")
            self.state_mgr.set_stage(DeploymentStage.COMPLETE)
            return True
        
        # Build payload from outputs
        outputs = get_tofu_outputs()
        onboarding = outputs.get('clusterra_onboarding', {}).get('value', {})
        
        payload = {
            "cluster_name": self.state.cluster_name,
            "aws_account_id": onboarding.get("aws_account_id", ""),
            "region": self.state.region,
            "lattice_service_endpoint": onboarding.get("lattice_service_endpoint", ""),
            "lattice_service_network_id": onboarding.get("lattice_service_network_id", ""),
            "slurm_port": int(onboarding.get("slurm_port", 6830)),
            "slurm_jwt_secret_arn": onboarding.get("slurm_jwt_secret_arn", ""),
            "iam_role_arn": onboarding.get("role_arn", ""),
            "iam_external_id": onboarding.get("external_id", ""),
            "head_node_instance_id": self.state.head_node_instance_id,
        }
        
        url = f"{self.api_url}/v1/clusters/connect/{self.state.tenant_id}"
        console.print(f"[cyan]→ POST {url}[/cyan]")
        
        try:
            response = requests.post(url, json=payload, timeout=30)
            
            if response.status_code == 201:
                cluster = response.json()
                cluster_id = cluster.get('cluster_id')
                console.print(f"[green]✓ Registered! Cluster ID: {cluster_id}[/green]")
                self.state_mgr.update(cluster_id=cluster_id)
            else:
                console.print(f"[yellow]⚠ Registration returned {response.status_code}[/yellow]")
                console.print(f"[dim]{response.text}[/dim]")
        except requests.exceptions.RequestException as e:
            console.print(f"[yellow]⚠ API call failed: {e}[/yellow]")
        
        self.state_mgr.set_stage(DeploymentStage.COMPLETE)
        console.print(Panel("[bold green]✅ Deployment Complete![/bold green]", border_style="green"))
        return True
    
    def _run_stage_events(self, dry_run: bool) -> bool:
        """Stage 3a: Deploy events module."""
        console.print(Panel("[bold]Stage 3a: Events Infrastructure[/bold]", border_style="blue"))
        
        if not self.state.cluster_id or not self.state.tenant_id:
            console.print("[dim]Skipping events module (no cluster_id/tenant_id)[/dim]")
            self.state_mgr.set_stage(DeploymentStage.STAGE_4A_REGISTER)
            return self._run_stage_register(dry_run)
        
        if dry_run:
            console.print("[yellow]🔸 Dry run - would deploy events module[/yellow]")
            self.state_mgr.set_stage(DeploymentStage.STAGE_4A_REGISTER)
            return True
        
        # Update tfvars with cluster_id and tenant_id
        tfvars_path = Path.cwd() / 'terraform.tfvars'
        tfvars_content = tfvars_path.read_text() if tfvars_path.exists() else ""
        
        additions = []
        if 'cluster_id' not in tfvars_content:
            additions.append(f'cluster_id = "{self.state.cluster_id}"')
        if 'tenant_id' not in tfvars_content:
            additions.append(f'tenant_id = "{self.state.tenant_id}"')
        
        if additions:
            with tfvars_path.open('a') as f:
                f.write('\n' + '\n'.join(additions) + '\n')
        
        # Run tofu apply for events module
        if not run_tofu_apply(target_module="events"):
            self.state_mgr.set_failed("tofu apply (events) failed")
            return False
        
        self.state_mgr.set_stage(DeploymentStage.STAGE_4A_REGISTER)
        return self._run_stage_register(dry_run)
    
    def _retry_from_last_good_stage(self, dry_run: bool) -> bool:
        """Retry from the last successful stage."""
        # Map failed stage to previous good stage
        stage_order = list(DeploymentStage)
        current_idx = stage_order.index(DeploymentStage.FAILED)
        
        # Find which stage actually failed by looking at what data we have
        if self.state.cluster_id:
            self.state_mgr.set_stage(DeploymentStage.STAGE_3A_EVENTS)
        elif self.state.lattice_service_endpoint:
            self.state_mgr.set_stage(DeploymentStage.STAGE_3A_EVENTS)
        elif self.state.head_node_instance_id:
            self.state_mgr.set_stage(DeploymentStage.STAGE_2A_CONNECTIVITY)
        elif self.state.pcluster_config_path:
            self.state_mgr.set_stage(DeploymentStage.STAGE_1B_PCLUSTER_PENDING)
        else:
            self.state_mgr.set_stage(DeploymentStage.STAGE_1A_GENERATE_CONFIG)
        
        return self.run(dry_run)


# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE PROMPTS
# ─────────────────────────────────────────────────────────────────────────────

def gather_initial_config(session: boto3.Session, state_mgr: StateManager) -> bool:
    """Gather initial configuration through interactive prompts."""
    state = state_mgr.state
    
    # Scenario selection
    scenario = questionary.select(
        "What would you like to do?",
        choices=[
            questionary.Choice("🆕 New Cluster - Deploy fresh ParallelCluster", value="new"),
            questionary.Choice("🔗 Existing Cluster - Connect existing cluster", value="existing"),
        ],
        style=PROMPT_STYLE
    ).ask()
    
    if not scenario:
        return False
    
    state_mgr.update(scenario=scenario, region=session.region_name)
    
    # ─── EXISTING CLUSTER: Simple flow ───
    if scenario == "existing":
        console.print()
        console.print("[bold]Connect Existing Cluster[/bold]")
        console.print("[dim]We'll derive VPC, subnet, and cluster name from the head node.[/dim]")
        console.print()
        
        # Just ask for instance ID
        head_node_id = questionary.text(
            "Head node instance ID (i-xxx):",
            validate=lambda x: x.startswith("i-") and len(x) > 3,
            style=PROMPT_STYLE
        ).ask()
        
        if not head_node_id:
            return False
        
        # Look up instance details
        console.print(f"[dim]Looking up instance {head_node_id}...[/dim]")
        ec2 = session.client('ec2')
        try:
            response = ec2.describe_instances(InstanceIds=[head_node_id])
            instance = response['Reservations'][0]['Instances'][0]
            
            vpc_id = instance['VpcId']
            subnet_id = instance['SubnetId']
            
            # Get cluster name from parallelcluster tag
            cluster_name = None
            for tag in instance.get('Tags', []):
                if tag['Key'] == 'parallelcluster:cluster-name':
                    cluster_name = tag['Value']
                    break
            
            if not cluster_name:
                cluster_name = questionary.text(
                    "Cluster name (could not detect from tags):",
                    style=PROMPT_STYLE
                ).ask()
            
            console.print(f"[green]✓[/green] Cluster: [cyan]{cluster_name}[/cyan]")
            console.print(f"[green]✓[/green] VPC: [cyan]{vpc_id}[/cyan]")
            console.print(f"[green]✓[/green] Subnet: [cyan]{subnet_id}[/cyan]")
            
            state_mgr.update(
                head_node_instance_id=head_node_id,
                cluster_name=cluster_name,
                vpc_id=vpc_id,
                subnet_id=subnet_id,
            )
            
        except ClientError as e:
            console.print(f"[red]❌ Could not find instance: {e}[/red]")
            return False
    
    # ─── NEW CLUSTER: Full flow ───
    else:
        # Cluster name
        cluster_name = questionary.text(
            "Cluster name:",
            default="clusterra-demo",
            style=PROMPT_STYLE
        ).ask()
        
        if not cluster_name:
            return False
        
        state_mgr.update(cluster_name=cluster_name)
        
        # VPC selection
        vpcs = list_vpcs(session)
        if vpcs:
            if len(vpcs) == 1:
                vpc_id = vpcs[0]['id']
                console.print(f"[green]✓[/green] Using VPC: {vpc_id}")
            else:
                vpc_id = questionary.select(
                    "Select VPC:",
                    choices=[questionary.Choice(f"{v['id']} - {v['name']}", value=v['id']) for v in vpcs],
                    style=PROMPT_STYLE
                ).ask()
        else:
            vpc_id = questionary.text("VPC ID:", style=PROMPT_STYLE).ask()
        
        if not vpc_id:
            return False
        
        state_mgr.update(vpc_id=vpc_id)
        
        # Subnet selection
        subnets = list_subnets(session, vpc_id)
        public_subnets = [s for s in subnets if s['public']] or subnets
        
        if public_subnets:
            if len(public_subnets) == 1:
                subnet_id = public_subnets[0]['id']
                console.print(f"[green]✓[/green] Using subnet: {subnet_id}")
            else:
                subnet_id = questionary.select(
                    "Select subnet:",
                    choices=[questionary.Choice(f"{s['id']} - {s['name']} ({s['az']})", value=s['id']) for s in public_subnets],
                    style=PROMPT_STYLE
                ).ask()
        else:
            subnet_id = questionary.text("Subnet ID:", style=PROMPT_STYLE).ask()
        
        if not subnet_id:
            return False
        
        state_mgr.update(subnet_id=subnet_id)
    
    # ─── TENANT ID (required for both) ───
    console.print()
    console.print("[bold]Clusterra Registration[/bold]")
    console.print("[dim]Get your Tenant ID from console.clusterra.cloud → Settings[/dim]")
    
    tenant_id = questionary.text(
        "Clusterra Tenant ID (ten_xxx):",
        validate=lambda x: len(x) > 0 and x.startswith("ten_"),
        style=PROMPT_STYLE
    ).ask()
    
    if not tenant_id:
        console.print("[red]Tenant ID is required for Clusterra registration[/red]")
        return False
    
    state_mgr.update(tenant_id=tenant_id)
    
    return True


def display_state_summary(state: DeploymentState):
    """Display current deployment state."""
    table = Table(title="Deployment State", show_header=False, border_style="cyan")
    table.add_column("Field", style="dim")
    table.add_column("Value", style="green")
    
    # Show stage with appropriate styling
    stage_style = "red" if state.stage == DeploymentStage.FAILED else "green"
    table.add_row("Stage", f"[{stage_style}]{state.stage.value}[/{stage_style}]")
    
    table.add_row("Scenario", state.scenario or "not set")
    table.add_row("Cluster", state.cluster_name or "not set")
    table.add_row("Region", state.region or "not set")
    
    if state.head_node_instance_id:
        table.add_row("Head Node", state.head_node_instance_id)
    if state.cluster_id:
        table.add_row("Clusterra ID", state.cluster_id)
    
    # Show error message if failed
    if state.stage == DeploymentStage.FAILED and state.error_message:
        table.add_row("Error", f"[red]{state.error_message}[/red]")
    
    console.print(table)


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Clusterra Connect Interactive Installer")
    parser.add_argument('--profile', help='AWS profile to use')
    parser.add_argument('--region', help='AWS region')
    parser.add_argument('--dry-run', action='store_true', help='Simulate deployment')
    parser.add_argument('--reset', action='store_true', help='Clear saved state and start fresh')
    parser.add_argument('--status', action='store_true', help='Show current deployment state')
    parser.add_argument('--api-url', default=DEFAULT_API_URL, help='Clusterra API URL')
    args = parser.parse_args()
    
    # Banner
    console.print(Panel.fit(
        "[bold cyan]Clusterra Connect[/bold cyan]\n[dim]Staged Deployment Orchestrator[/dim]",
        border_style="cyan"
    ))
    console.print()
    
    # State management
    state_file = Path.cwd() / STATE_FILE
    state_mgr = StateManager(state_file)
    
    # Handle --reset
    if args.reset:
        state_mgr.clear()
        console.print("[green]✓ State cleared[/green]")
        return
    
    # Handle --status
    if args.status:
        display_state_summary(state_mgr.state)
        return
    
    # AWS session
    try:
        session = get_aws_session(args.profile, args.region)
    except NoCredentialsError:
        console.print("[red]❌ No AWS credentials found[/red]")
        sys.exit(1)
    
    # Region check
    region = detect_region(session)
    if not region:
        region = questionary.text("AWS Region:", default='us-east-1', style=PROMPT_STYLE).ask()
        session = get_aws_session(args.profile, region)
    else:
        console.print(f"[green]✓[/green] Region: {region}")
    
    console.print()
    
    # Check for existing state (auto-detect resume)
    if state_mgr.state.stage != DeploymentStage.NOT_STARTED:
        display_state_summary(state_mgr.state)
        console.print()
        
        if state_mgr.state.stage == DeploymentStage.COMPLETE:
            console.print("[green]Deployment already complete![/green]")
            if not questionary.confirm("Start a new deployment?", default=False, style=PROMPT_STYLE).ask():
                return
            state_mgr.clear()
        elif state_mgr.state.stage == DeploymentStage.FAILED:
            # Determine what stage we'll retry from based on FSM state
            retry_stage = "unknown"
            error_msg = state_mgr.state.error_message.lower()
            
            # Use both state data AND error message to determine retry stage
            if state_mgr.state.cluster_id:
                retry_stage = "3a_events (Events Setup)"
            elif state_mgr.state.lattice_service_endpoint:
                retry_stage = "3a_events (Events Setup)"  
            elif state_mgr.state.head_node_instance_id:
                retry_stage = "2a_connectivity (Connectivity)"
            elif "connectivity" in error_msg or ("tofu" in error_msg and state_mgr.state.pcluster_config_path):
                # If error mentions connectivity or tofu (and config exists), cluster creation likely completed
                retry_stage = "2a_connectivity (Connectivity - cluster exists, retry connectivity)"
            elif state_mgr.state.pcluster_config_path:
                retry_stage = "1b_pcluster_pending (Cluster Creation)" 
            else:
                retry_stage = "1a_generate_config (Config Generation)"
            
            console.print(f"[yellow]Will retry from: {retry_stage}[/yellow]")
            
            if questionary.confirm("Resume from failed deployment?", default=True, style=PROMPT_STYLE).ask():
                orchestrator = Orchestrator(state_mgr, session, args.api_url)
                orchestrator.run(args.dry_run)
                return
            else:
                if questionary.confirm("Start fresh?", default=False, style=PROMPT_STYLE).ask():
                    state_mgr.clear()
                else:
                    return
        else:
            if questionary.confirm(f"Resume from {state_mgr.state.stage.value}?", default=True, style=PROMPT_STYLE).ask():
                orchestrator = Orchestrator(state_mgr, session, args.api_url)
                orchestrator.run(args.dry_run)
                return
            else:
                if questionary.confirm("Start fresh?", default=False, style=PROMPT_STYLE).ask():
                    state_mgr.clear()
                else:
                    return
    
    # Initial configuration
    if not gather_initial_config(session, state_mgr):
        console.print("[yellow]Cancelled[/yellow]")
        return
    
    # Run pre-flight checks (scenario-aware: pcluster only required for new clusters)
    if not run_preflight_checks(state_mgr.state.scenario):
        sys.exit(1)
    
    # Generate tfvars
    ssh_key = ""
    if state_mgr.state.scenario == "new":
        keys = list_ssh_keys(session)
        if keys:
            ssh_key = questionary.select("SSH key pair:", choices=keys, style=PROMPT_STYLE).ask()
        else:
            ssh_key = questionary.text("SSH key name:", style=PROMPT_STYLE).ask()
    
    tfvars_content = generate_tfvars(state_mgr.state, ssh_key)
    tfvars_path = Path.cwd() / 'terraform.tfvars'
    tfvars_path.write_text(tfvars_content)
    console.print(f"[green]✓[/green] Created terraform.tfvars")
    
    # Confirm and run
    console.print()
    display_state_summary(state_mgr.state)
    console.print()
    
    if not questionary.confirm("Proceed with deployment?", default=True, style=PROMPT_STYLE).ask():
        console.print("[yellow]Cancelled. Run again to continue.[/yellow]")
        return
    
    # Run orchestrator
    orchestrator = Orchestrator(state_mgr, session, args.api_url)
    orchestrator.run(args.dry_run)


if __name__ == '__main__':
    main()
