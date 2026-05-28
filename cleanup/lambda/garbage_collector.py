import boto3
import json
from datetime import datetime, timedelta, timezone

ec2 = boto3.client("ec2")
cloudwatch = boto3.client("cloudwatch")

# An instance with avg CPU below this % over the lookback window is considered idle
CPU_IDLE_THRESHOLD = 5.0
IDLE_LOOKBACK_DAYS = 7


def get_instance_avg_cpu(instance_id):
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=IDLE_LOOKBACK_DAYS)

    response = cloudwatch.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=start,
        EndTime=end,
        Period=86400,
        Statistics=["Average"],
    )
    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return None
    return sum(d["Average"] for d in datapoints) / len(datapoints)


def instance_age_days(launch_time):
    return (datetime.now(timezone.utc) - launch_time).days


def delete_unattached_ebs_volumes():
    deleted = []
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for vol in page["Volumes"]:
            vol_id = vol["VolumeId"]
            size_gb = vol["Size"]
            try:
                ec2.delete_volume(VolumeId=vol_id)
                deleted.append({"volume_id": vol_id, "size_gb": size_gb})
                print(f"Deleted EBS volume {vol_id} ({size_gb} GiB)")
            except Exception as e:
                print(f"Failed to delete volume {vol_id}: {e}")
    return deleted


def release_unassociated_eips():
    released = []
    paginator = ec2.get_paginator("describe_addresses")
    for page in paginator.paginate():
        for addr in page["Addresses"]:
            # No AssociationId means not attached to any instance or network interface
            if "AssociationId" not in addr:
                allocation_id = addr.get("AllocationId")
                public_ip = addr.get("PublicIp")
                try:
                    ec2.release_address(AllocationId=allocation_id)
                    released.append({"public_ip": public_ip, "allocation_id": allocation_id})
                    print(f"Released Elastic IP {public_ip} ({allocation_id})")
                except Exception as e:
                    print(f"Failed to release EIP {public_ip}: {e}")
    return released


def terminate_idle_ec2_instances():
    terminated = []
    skipped = []

    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                instance_id = instance["InstanceId"]
                launch_time = instance["LaunchTime"]
                age_days = instance_age_days(launch_time)

                # Skip instances younger than the lookback window — not enough data yet
                if age_days < IDLE_LOOKBACK_DAYS:
                    skipped.append({"instance_id": instance_id, "reason": "too_young", "age_days": age_days})
                    print(f"Skipping {instance_id} — only {age_days} day(s) old")
                    continue

                avg_cpu = get_instance_avg_cpu(instance_id)

                # No CloudWatch data after 7 days also signals an idle instance
                is_idle = avg_cpu is None or avg_cpu < CPU_IDLE_THRESHOLD

                if is_idle:
                    try:
                        ec2.terminate_instances(InstanceIds=[instance_id])
                        terminated.append({
                            "instance_id": instance_id,
                            "avg_cpu_percent": avg_cpu,
                            "age_days": age_days,
                        })
                        print(f"Terminated idle instance {instance_id} (avg CPU: {avg_cpu}%)")
                    except Exception as e:
                        print(f"Failed to terminate {instance_id}: {e}")
                else:
                    skipped.append({
                        "instance_id": instance_id,
                        "reason": "active",
                        "avg_cpu_percent": avg_cpu,
                    })

    return {"terminated": terminated, "skipped": skipped}


def lambda_handler(event, context):
    print("Starting zombie resource garbage collection...")

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "deleted_ebs_volumes": delete_unattached_ebs_volumes(),
        "released_eips": release_unassociated_eips(),
        "ec2_instances": terminate_idle_ec2_instances(),
    }

    print("Garbage collection complete.")
    print(json.dumps(report, indent=2, default=str))
    return report
