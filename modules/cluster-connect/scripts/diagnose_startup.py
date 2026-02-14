import boto3
import time
import argparse


def send_ssm_command(instance_id, commands, session):
    ssm = session.client("ssm")
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
        )
        cmd_id = resp["Command"]["CommandId"]
        time.sleep(2)
        for _ in range(30):
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] == "Success":
                return True, inv["StandardOutputContent"]
            elif inv["Status"] in ["Failed", "Cancelled", "TimedOut"]:
                return False, inv.get("StandardErrorContent", "") or "Command failed"
            time.sleep(2)
    except Exception as e:
        return False, str(e)
    return False, "Timeout"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--region", default="ap-south-1")
    parser.add_argument("--profile", default=None)
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)

    commands = [
        "echo '=== Service Status ==='",
        "systemctl status slurmrestd --no-pager",
        "echo '=== Journal Logs ==='",
        "journalctl -u slurmrestd -n 50 --no-pager",
        "echo '=== Key Permissions ==='",
        "ls -l /opt/slurm/etc/jwt_hs256.key",
        "echo '=== Socket Permissions ==='",
        "ls -l /var/run/munge/munge.socket.2",
        "echo '=== User Check ==='",
        "id slurm",
        "echo '=== Conf Check ==='",
        "grep Auth /opt/slurm/etc/slurm.conf",
    ]

    print(f"Running startup diagnostics on {args.instance_id}...")
    success, output = send_ssm_command(args.instance_id, commands, session)

    if success:
        print(output)
    else:
        print(f"Failed: {output}")


if __name__ == "__main__":
    main()
