"""Zombie resource garbage collector.

Sweeps every enabled AWS region and reclaims three classes of waste:

  1. Unattached EBS volumes   (state == "available")        -> DeleteVolume
  2. Unassociated Elastic IPs (no AssociationId)            -> ReleaseAddress
  3. Idle zombie EC2 instances                              -> TerminateInstances

Termination is deliberately conservative. An instance is only terminated when
ALL of the following hold:

  * it is tagged {ZOMBIE_TAG_KEY}={ZOMBIE_TAG_VALUE} (disposable by design),
  * it is older than IDLE_LOOKBACK_DAYS (enough CloudWatch history to judge),
  * its average CPU over the lookback window is below CPU_IDLE_THRESHOLD.

The tag requirement is enforced twice — here in code AND in the Lambda's IAM
policy — so a logic regression still cannot terminate an untagged production
instance.
"""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3

CPU_IDLE_THRESHOLD = float(os.environ.get("CPU_IDLE_THRESHOLD", "5.0"))
IDLE_LOOKBACK_DAYS = int(os.environ.get("IDLE_LOOKBACK_DAYS", "7"))
ZOMBIE_TAG_KEY = os.environ.get("ZOMBIE_TAG_KEY", "Type")
ZOMBIE_TAG_VALUE = os.environ.get("ZOMBIE_TAG_VALUE", "ZombieAsset")


def list_enabled_regions(ec2_client):
    """Return every region enabled for this account."""
    resp = ec2_client.describe_regions(AllRegions=False)
    return [r["RegionName"] for r in resp["Regions"]]


def get_instance_avg_cpu(cloudwatch, instance_id, lookback_days=IDLE_LOOKBACK_DAYS, now=None):
    now = now or datetime.now(timezone.utc)
    start = now - timedelta(days=lookback_days)

    response = cloudwatch.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=start,
        EndTime=now,
        Period=86400,
        Statistics=["Average"],
    )
    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return None
    return sum(d["Average"] for d in datapoints) / len(datapoints)


def instance_age_days(launch_time, now=None):
    now = now or datetime.now(timezone.utc)
    return (now - launch_time).days


def is_zombie_tagged(instance, tag_key=ZOMBIE_TAG_KEY, tag_value=ZOMBIE_TAG_VALUE):
    """True only if the instance carries the disposable-asset tag."""
    for tag in instance.get("Tags", []):
        if tag.get("Key") == tag_key and tag.get("Value") == tag_value:
            return True
    return False


def delete_unattached_ebs_volumes(ec2_client, region):
    deleted = []
    paginator = ec2_client.get_paginator("describe_volumes")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for vol in page["Volumes"]:
            vol_id = vol["VolumeId"]
            size_gb = vol["Size"]
            try:
                ec2_client.delete_volume(VolumeId=vol_id)
                deleted.append({"region": region, "volume_id": vol_id, "size_gb": size_gb})
                print(f"[{region}] Deleted EBS volume {vol_id} ({size_gb} GiB)")
            except Exception as e:
                print(f"[{region}] Failed to delete volume {vol_id}: {e}")
    return deleted


def release_unassociated_eips(ec2_client, region):
    released = []
    # describe_addresses is not paginated; it returns all addresses at once.
    for addr in ec2_client.describe_addresses().get("Addresses", []):
        # No AssociationId means it is not attached to any instance or ENI.
        if "AssociationId" not in addr:
            allocation_id = addr.get("AllocationId")
            public_ip = addr.get("PublicIp")
            try:
                ec2_client.release_address(AllocationId=allocation_id)
                released.append({"region": region, "public_ip": public_ip, "allocation_id": allocation_id})
                print(f"[{region}] Released Elastic IP {public_ip} ({allocation_id})")
            except Exception as e:
                print(f"[{region}] Failed to release EIP {public_ip}: {e}")
    return released


def terminate_idle_zombie_instances(ec2_client, cloudwatch, region, now=None):
    now = now or datetime.now(timezone.utc)
    terminated = []
    skipped = []

    paginator = ec2_client.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                instance_id = instance["InstanceId"]

                # Gate 1 — only ever touch instances tagged as disposable.
                if not is_zombie_tagged(instance):
                    skipped.append({"region": region, "instance_id": instance_id, "reason": "not_zombie_tagged"})
                    continue

                # Gate 2 — skip instances younger than the lookback window.
                age_days = instance_age_days(instance["LaunchTime"], now=now)
                if age_days < IDLE_LOOKBACK_DAYS:
                    skipped.append({"region": region, "instance_id": instance_id, "reason": "too_young", "age_days": age_days})
                    print(f"[{region}] Skipping {instance_id} — only {age_days} day(s) old")
                    continue

                # Gate 3 — must be idle. No datapoints after the window also reads as idle.
                avg_cpu = get_instance_avg_cpu(cloudwatch, instance_id, now=now)
                if avg_cpu is None or avg_cpu < CPU_IDLE_THRESHOLD:
                    try:
                        ec2_client.terminate_instances(InstanceIds=[instance_id])
                        terminated.append({"region": region, "instance_id": instance_id, "avg_cpu_percent": avg_cpu, "age_days": age_days})
                        print(f"[{region}] Terminated idle zombie instance {instance_id} (avg CPU: {avg_cpu}%)")
                    except Exception as e:
                        print(f"[{region}] Failed to terminate {instance_id}: {e}")
                else:
                    skipped.append({"region": region, "instance_id": instance_id, "reason": "active", "avg_cpu_percent": avg_cpu})

    return {"terminated": terminated, "skipped": skipped}


def collect_region(region, now=None):
    """Run all three sweeps in a single region."""
    ec2_client = boto3.client("ec2", region_name=region)
    cloudwatch = boto3.client("cloudwatch", region_name=region)
    return {
        "deleted_ebs_volumes": delete_unattached_ebs_volumes(ec2_client, region),
        "released_eips": release_unassociated_eips(ec2_client, region),
        "ec2_instances": terminate_idle_zombie_instances(ec2_client, cloudwatch, region, now=now),
    }


def lambda_handler(event, context):
    print("Starting multi-region zombie resource garbage collection...")
    now = datetime.now(timezone.utc)

    bootstrap = boto3.client("ec2")
    regions = list_enabled_regions(bootstrap)
    print(f"Scanning {len(regions)} region(s): {', '.join(regions)}")

    report = {"timestamp": now.isoformat(), "regions": {}}
    for region in regions:
        try:
            report["regions"][region] = collect_region(region, now=now)
        except Exception as e:
            print(f"[{region}] Region sweep failed: {e}")
            report["regions"][region] = {"error": str(e)}

    print("Garbage collection complete.")
    print(json.dumps(report, indent=2, default=str))
    return report
