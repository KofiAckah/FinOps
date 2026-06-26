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
from botocore.config import Config

CPU_IDLE_THRESHOLD = float(os.environ.get("CPU_IDLE_THRESHOLD", "5.0"))
IDLE_LOOKBACK_DAYS = int(os.environ.get("IDLE_LOOKBACK_DAYS", "7"))
ZOMBIE_TAG_KEY = os.environ.get("ZOMBIE_TAG_KEY", "Type")
ZOMBIE_TAG_VALUE = os.environ.get("ZOMBIE_TAG_VALUE", "ZombieAsset")

# Explicit timeouts so a slow region can never hang the whole Lambda invocation.
# (Config has no region/credential dependency, so it's safe to build at import.)
BOTO_CONFIG = Config(connect_timeout=10, read_timeout=30, retries={"max_attempts": 3})


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


def _iter_running_instances(ec2_client):
    paginator = ec2_client.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page["Reservations"]:
            yield from reservation["Instances"]


def evaluate_instance(instance, cloudwatch, region, now):
    """Apply the three termination gates. Returns (terminate?, outcome_record)."""
    instance_id = instance["InstanceId"]
    base = {"region": region, "instance_id": instance_id}

    # Gate 1 — only ever touch instances tagged as disposable.
    if not is_zombie_tagged(instance):
        return False, {**base, "reason": "not_zombie_tagged"}

    # Gate 2 — skip instances younger than the lookback window.
    age_days = instance_age_days(instance["LaunchTime"], now=now)
    if age_days < IDLE_LOOKBACK_DAYS:
        return False, {**base, "reason": "too_young", "age_days": age_days}

    # Gate 3 — must be idle. No datapoints after the window also reads as idle.
    avg_cpu = get_instance_avg_cpu(cloudwatch, instance_id, now=now)
    if avg_cpu is None or avg_cpu < CPU_IDLE_THRESHOLD:
        return True, {**base, "avg_cpu_percent": avg_cpu, "age_days": age_days}
    return False, {**base, "reason": "active", "avg_cpu_percent": avg_cpu}


def terminate_idle_zombie_instances(ec2_client, cloudwatch, region, now=None):
    now = now or datetime.now(timezone.utc)
    terminated = []
    skipped = []

    for instance in _iter_running_instances(ec2_client):
        should_terminate, record = evaluate_instance(instance, cloudwatch, region, now)
        if not should_terminate:
            skipped.append(record)
            continue
        try:
            ec2_client.terminate_instances(InstanceIds=[record["instance_id"]])
            terminated.append(record)
            print(f"[{region}] Terminated idle zombie instance {record['instance_id']} (avg CPU: {record['avg_cpu_percent']}%)")
        except Exception as e:
            print(f"[{region}] Failed to terminate {record['instance_id']}: {e}")
            skipped.append({**record, "reason": "terminate_failed", "error": str(e)})

    return {"terminated": terminated, "skipped": skipped}


def collect_region(region, now=None):
    """Run all three sweeps in a single region."""
    ec2_client = boto3.client("ec2", region_name=region, config=BOTO_CONFIG)
    cloudwatch = boto3.client("cloudwatch", region_name=region, config=BOTO_CONFIG)
    return {
        "deleted_ebs_volumes": delete_unattached_ebs_volumes(ec2_client, region),
        "released_eips": release_unassociated_eips(ec2_client, region),
        "ec2_instances": terminate_idle_zombie_instances(ec2_client, cloudwatch, region, now=now),
    }


def lambda_handler(event, context):
    print("Starting multi-region zombie resource garbage collection...")
    now = datetime.now(timezone.utc)

    bootstrap = boto3.client("ec2", config=BOTO_CONFIG)
    regions = list_enabled_regions(bootstrap)
    print(f"Scanning {len(regions)} region(s): {', '.join(regions)}")

    report = {"timestamp": now.isoformat(), "regions": {}}
    for region in regions:
        try:
            report["regions"][region] = collect_region(region, now=now)
        except Exception as e:
            msg = str(e)
            # Org SCPs / disabled regions deny EC2 calls — that's expected, not a
            # failure. Record it concisely instead of dumping the raw error blob.
            if any(code in msg for code in ("UnauthorizedOperation", "AccessDenied", "AuthFailure")):
                print(f"[{region}] Skipped — no access (SCP or region disabled)")
                report["regions"][region] = {"skipped": "no_access_scp_or_disabled"}
            else:
                print(f"[{region}] Region sweep failed: {e}")
                report["regions"][region] = {"error": msg}

    print("Garbage collection complete.")
    print(json.dumps(report, indent=2, default=str))
    return report
