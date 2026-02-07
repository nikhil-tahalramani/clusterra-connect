#!/usr/bin/env python3
"""
Clusterra Connect Uninstaller
Removes resources provisioned by install.py:
1. Deletes ParallelCluster stack (via pcluster CLI)
2. Destroys Tofu resources (Connectivity, Events) IF managing the target cluster
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Dependency Check
try:
    import boto3
    from botocore.exceptions import ClientError, ProfileNotFound
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
    from rich.progress import Progress, SpinnerColumn, TextColumn
except ImportError:
    print("❌ rich is required. Install with: pip install rich")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

console = Console()

PROMPT_STYLE = Style(
    [
        ("qmark", "fg:cyan bold"),
        ("question", "bold"),
        ("answer", "fg:green"),
        ("pointer", "fg:cyan bold"),
        ("highlighted", "fg:cyan"),
        ("selected", "fg:green"),
    ]
)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────


def get_aws_session(
    profile: str | None = None, region: str | None = None
) -> boto3.Session:
    try:
        return boto3.Session(profile_name=profile, region_name=region)
    except ProfileNotFound:
        console.print(f"[red]❌ AWS profile '{profile}' not found[/red]")
        sys.exit(1)


def load_tfvars() -> dict:
    """Load current cluster config from tfvars."""
    path = Path("generated/terraform.tfvars")
    if not path.exists():
        return {}

    config = {}
    import re

    content = path.read_text()
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r'(\w+)\s*=\s*"?([^"]*)"?', line)
        if match:
            config[match.group(1)] = match.group(2)
    return config


def get_pcluster_status(cluster_name: str, session: boto3.Session) -> str:
    cfn = session.client("cloudformation")
    try:
        response = cfn.describe_stacks(StackName=cluster_name)
        if response["Stacks"]:
            return response["Stacks"][0]["StackStatus"]
    except ClientError:
        return "NOT_FOUND"
    return "NOT_FOUND"


# ─────────────────────────────────────────────────────────────────────────────
# PHASES
# ─────────────────────────────────────────────────────────────────────────────


def delete_pcluster(
    cluster_name: str, region: str, dry_run: bool, session: boto3.Session
) -> bool:
    """Delete the ParallelCluster CloudFormation stack."""
    # path = shutil.which("pcluster")
    status = get_pcluster_status(cluster_name, session)

    if status == "NOT_FOUND":
        console.print(
            f"[yellow]⚠ Cluster '{cluster_name}' not found in CloudFormation. Skipping delete.[/yellow]"
        )
        return True

    console.print(
        Panel(
            f"[bold]Deleting ParallelCluster: {cluster_name}[/bold]", border_style="red"
        )
    )

    if dry_run:
        console.print("[yellow]Dry Run: Would run pcluster delete-cluster[/yellow]")
        return True

    # 1. Trigger Deletion
    console.print(
        f"[cyan]→ pcluster delete-cluster --cluster-name {cluster_name} ...[/cyan]"
    )
    cmd = [
        "pcluster",
        "delete-cluster",
        "--cluster-name",
        cluster_name,
        "--region",
        region,
    ]
    if subprocess.run(cmd).returncode != 0:
        console.print("[red]❌ Delete command failed[/red]")
        return False

    # 2. Wait Loop
    console.print(f"[dim]Waiting for deletion (Current: {status})...[/dim]")
    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), console=console
    ) as progress:
        task = progress.add_task("Deleting Cluster...", total=None)
        while True:
            time.sleep(10)
            status = get_pcluster_status(cluster_name, session)

            if status == "NOT_FOUND" or "DELETE_COMPLETE" in status:
                progress.update(task, description="[green]✓ Cluster deleted[/green]")
                return True

            if "DELETE_FAILED" in status:
                progress.update(
                    task, description=f"[red]❌ Deletion failed: {status}[/red]"
                )
                return False

            progress.update(task, description=f"Status: {status}")


def destroy_tofu_resources(dry_run: bool):
    """Run tofu destroy."""
    console.print(Panel("[bold]Destroying Tofu Resources[/bold]", border_style="red"))

    if dry_run:
        console.print("[yellow]Dry Run: Would run tofu destroy[/yellow]")
        return

    console.print("[cyan]→ tofu destroy -auto-approve[/cyan]")

    # Run destroy
    subprocess.run(
        ["tofu", "destroy", "-auto-approve", "-var-file=generated/terraform.tfvars"],
        cwd=Path.cwd(),
    )


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Clusterra Uninstall Script")
    parser.add_argument("--profile", help="AWS profile to use")
    parser.add_argument("--region", help="AWS region")
    parser.add_argument("--dry-run", action="store_true", help="Simulate actions")
    # Optional arguments to skip prompts
    parser.add_argument("--cluster-name", help="Name of cluster to delete")
    parser.add_argument("--force", action="store_true", help="Skip confirmation")
    args = parser.parse_args()

    # 1. Setup Session
    session = get_aws_session(args.profile, args.region)
    region = args.region or session.region_name
    if not region:
        console.print(
            "[red]❌ No region specified. Use --region or configured profile.[/red]"
        )
        sys.exit(1)

    # 2. Identify Target & Validation
    tfvars = load_tfvars()
    default_name = tfvars.get("cluster_name", "")
    default_id = tfvars.get("cluster_id", "")

    if args.cluster_name:
        cluster_name = args.cluster_name
    else:
        questions = [
            {
                "type": "text",
                "name": "cluster_name",
                "message": "Which cluster NAME would you like to delete?",
                "default": default_name,
                "validate": lambda val: len(val.strip()) > 0 or "Required",
            }
        ]
        answers = questionary.prompt(questions, style=PROMPT_STYLE)
        if not answers:
            sys.exit(0)
        cluster_name = answers["cluster_name"]

    # 3. Confirmation (Dual-factor)
    if not args.force:
        console.print("\n[bold red]WARNING: This will PERMANENTLY DELETE:[/bold red]")
        console.print(f"  1. ParallelCluster stack '{cluster_name}'")

        # Check if Tofu state matches
        tofu_match = default_name == cluster_name
        if tofu_match:
            console.print(
                "  2. Associated Connectivity & Event Infrastructure (Tofu resources)"
            )
            console.print(f"     Target Cluster ID: {default_id}")
        else:
            console.print(
                f"  [dim](Skipping Tofu destroy: active state is for '{default_name}', not '{cluster_name}')[/dim]"
            )

        console.print()

        # Ask for Cluster ID to confirm
        confirm_id = questionary.text(
            f"To confirm, please enter the CLUSTER ID (e.g. {default_id if default_id else 'clus...'}):",
            validate=lambda val: len(val) == 8
            and val.startswith("clus")
            or "Must be valid ID (clus...)",
        ).ask()

        if confirm_id is None:
            sys.exit(0)

        # If we are potentially destroying Tofu, ID *must* match tfvars
        if tofu_match and confirm_id != default_id:
            console.print(
                f"[red]❌ Mismatch! You entered '{confirm_id}' but active Tofu state is '{default_id}'.[/red]"
            )
            console.print(
                "[red]Aborting to prevent accidental deletion of wrong resources.[/red]"
            )
            sys.exit(1)

        # If just deleting pcluster (no tofu match), we just trust they know the ID or we could warn.
        # But honestly, if tofu doesn't match, we aren't using the ID for anything except "I know what I'm doing".
        # Let's at least check if they typed the ID they THOUGHT they were deleting.

    # 4. Delete Pcluster
    if not delete_pcluster(cluster_name, region, args.dry_run, session):
        console.print("[red]Failed to delete cluster stack. Stopping.[/red]")
        sys.exit(1)

    # 5. Destroy Tofu (Conditional)
    if default_name == cluster_name:
        destroy_tofu_resources(args.dry_run)

        # Cleanup generated files
        if not args.dry_run:
            shutil.rmtree("generated", ignore_errors=True)
            console.print("[gray]Removed generated/ directory[/gray]")

            # Remove state files
            for f in ["terraform.tfstate", "terraform.tfstate.backup"]:
                if os.path.exists(f):
                    os.remove(f)
                    console.print(f"[gray]Removed {f}[/gray]")
    else:
        console.print(
            f"[yellow]⚠ Preserving Tofu state (belongs to '{default_name}')[/yellow]"
        )

    console.print("\n[bold green]Uninstall Complete![/bold green]")


if __name__ == "__main__":
    main()
