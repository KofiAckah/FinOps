"""Unit tests for the zombie garbage collector.

These exercise the decision logic with mocked boto3 clients — no AWS calls and
no credentials required. Run with:

    pip install -r tests/requirements.txt
    pytest -v
"""
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import garbage_collector as gc

NOW = datetime(2026, 6, 26, 12, 0, 0, tzinfo=timezone.utc)
OLD = NOW - timedelta(days=30)
YOUNG = NOW - timedelta(days=2)

ZOMBIE_TAGS = [{"Key": "Type", "Value": "ZombieAsset"}]
OTHER_TAGS = [{"Key": "Type", "Value": "Production"}]


def _paginated(client, op, pages):
    """Wire client.get_paginator(op).paginate(...) to yield `pages`."""
    paginator = MagicMock()
    paginator.paginate.return_value = pages
    client.get_paginator.side_effect = lambda name: paginator if name == op else MagicMock()
    return client


# ─── tag gate ──────────────────────────────────────────────────────────────

def test_is_zombie_tagged_true():
    assert gc.is_zombie_tagged({"Tags": ZOMBIE_TAGS}) is True


def test_is_zombie_tagged_false_wrong_value():
    assert gc.is_zombie_tagged({"Tags": OTHER_TAGS}) is False


def test_is_zombie_tagged_false_no_tags():
    assert gc.is_zombie_tagged({}) is False


# ─── age + cpu helpers ───────────────────────────────────────────────────────

def test_instance_age_days():
    assert gc.instance_age_days(OLD, now=NOW) == 30


def test_avg_cpu_none_when_no_datapoints():
    cw = MagicMock()
    cw.get_metric_statistics.return_value = {"Datapoints": []}
    assert gc.get_instance_avg_cpu(cw, "i-1", now=NOW) is None


def test_avg_cpu_averages_datapoints():
    cw = MagicMock()
    cw.get_metric_statistics.return_value = {"Datapoints": [{"Average": 2.0}, {"Average": 4.0}]}
    assert gc.get_instance_avg_cpu(cw, "i-1", now=NOW) == 3.0


# ─── EBS ────────────────────────────────────────────────────────────────────

def test_deletes_available_volumes():
    ec2 = MagicMock()
    _paginated(ec2, "describe_volumes", [{"Volumes": [
        {"VolumeId": "vol-1", "Size": 10},
        {"VolumeId": "vol-2", "Size": 20},
    ]}])
    deleted = gc.delete_unattached_ebs_volumes(ec2, "eu-west-1")
    assert {d["volume_id"] for d in deleted} == {"vol-1", "vol-2"}
    assert ec2.delete_volume.call_count == 2


# ─── EIP ─────────────────────────────────────────────────────────────────────

def test_releases_only_unassociated_eips():
    ec2 = MagicMock()
    ec2.describe_addresses.return_value = {"Addresses": [
        {"AllocationId": "eipalloc-1", "PublicIp": "1.1.1.1"},                       # unassociated
        {"AllocationId": "eipalloc-2", "PublicIp": "2.2.2.2", "AssociationId": "x"},  # in use
    ]}
    released = gc.release_unassociated_eips(ec2, "eu-west-1")
    assert [r["allocation_id"] for r in released] == ["eipalloc-1"]
    ec2.release_address.assert_called_once_with(AllocationId="eipalloc-1")


# ─── EC2 termination gates ────────────────────────────────────────────────────

def _instances_page(instances):
    return [{"Reservations": [{"Instances": instances}]}]


def test_skips_instance_not_zombie_tagged():
    ec2 = MagicMock()
    _paginated(ec2, "describe_instances", _instances_page([
        {"InstanceId": "i-prod", "LaunchTime": OLD, "Tags": OTHER_TAGS},
    ]))
    cw = MagicMock()
    result = gc.terminate_idle_zombie_instances(ec2, cw, "eu-west-1", now=NOW)
    ec2.terminate_instances.assert_not_called()
    assert result["skipped"][0]["reason"] == "not_zombie_tagged"


def test_skips_zombie_instance_too_young():
    ec2 = MagicMock()
    _paginated(ec2, "describe_instances", _instances_page([
        {"InstanceId": "i-new", "LaunchTime": YOUNG, "Tags": ZOMBIE_TAGS},
    ]))
    cw = MagicMock()
    result = gc.terminate_idle_zombie_instances(ec2, cw, "eu-west-1", now=NOW)
    ec2.terminate_instances.assert_not_called()
    assert result["skipped"][0]["reason"] == "too_young"


def test_terminates_old_idle_zombie():
    ec2 = MagicMock()
    _paginated(ec2, "describe_instances", _instances_page([
        {"InstanceId": "i-zombie", "LaunchTime": OLD, "Tags": ZOMBIE_TAGS},
    ]))
    cw = MagicMock()
    cw.get_metric_statistics.return_value = {"Datapoints": [{"Average": 1.0}]}  # idle
    result = gc.terminate_idle_zombie_instances(ec2, cw, "eu-west-1", now=NOW)
    ec2.terminate_instances.assert_called_once_with(InstanceIds=["i-zombie"])
    assert result["terminated"][0]["instance_id"] == "i-zombie"


def test_does_not_terminate_active_zombie():
    ec2 = MagicMock()
    _paginated(ec2, "describe_instances", _instances_page([
        {"InstanceId": "i-busy", "LaunchTime": OLD, "Tags": ZOMBIE_TAGS},
    ]))
    cw = MagicMock()
    cw.get_metric_statistics.return_value = {"Datapoints": [{"Average": 80.0}]}  # active
    result = gc.terminate_idle_zombie_instances(ec2, cw, "eu-west-1", now=NOW)
    ec2.terminate_instances.assert_not_called()
    assert result["skipped"][0]["reason"] == "active"


# ─── multi-region discovery ────────────────────────────────────────────────────

def test_lists_enabled_regions():
    ec2 = MagicMock()
    ec2.describe_regions.return_value = {"Regions": [
        {"RegionName": "eu-west-1"}, {"RegionName": "us-east-1"},
    ]}
    assert gc.list_enabled_regions(ec2) == ["eu-west-1", "us-east-1"]
