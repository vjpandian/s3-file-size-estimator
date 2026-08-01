#!/usr/bin/env python3
"""Report the total size and object count of every S3 bucket in the account.

Sizes are computed by paginating ListObjectsV2 and summing each object's
actual `Size` field, so the numbers reflect current byte-accurate usage
rather than the ~24h-delayed CloudWatch storage metrics.
"""

import sys

import boto3
from botocore.exceptions import ClientError

UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]


def human_readable(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in UNITS:
        if size < 1024 or unit == UNITS[-1]:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} {UNITS[-1]}"


def bucket_region(s3_client, bucket_name: str) -> str:
    location = s3_client.get_bucket_location(Bucket=bucket_name)["LocationConstraint"]
    # us-east-1 is reported as None/empty by this API
    return location or "us-east-1"


def measure_bucket(session: boto3.Session, bucket_name: str, region: str) -> tuple[int, int]:
    client = session.client("s3", region_name=region)
    paginator = client.get_paginator("list_objects_v2")

    total_bytes = 0
    total_objects = 0
    for page in paginator.paginate(Bucket=bucket_name):
        for obj in page.get("Contents", []):
            total_bytes += obj["Size"]
            total_objects += 1

    return total_bytes, total_objects


def main() -> int:
    session = boto3.Session()
    s3 = session.client("s3")

    try:
        buckets = s3.list_buckets()["Buckets"]
    except ClientError as exc:
        print(f"Failed to list buckets: {exc}", file=sys.stderr)
        return 1

    if not buckets:
        print("No buckets found in this account.")
        return 0

    results = []
    exit_code = 0

    for bucket in buckets:
        name = bucket["Name"]
        try:
            region = bucket_region(s3, name)
            total_bytes, total_objects = measure_bucket(session, name, region)
            results.append((name, total_bytes, total_objects, None))
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code", "Unknown")
            results.append((name, None, None, error_code))
            exit_code = 1

    name_width = max(len(r[0]) for r in results)

    print(f"{'BUCKET':<{name_width}}  {'SIZE':>12}  {'OBJECTS':>10}")
    print("-" * (name_width + 28))

    grand_total_bytes = 0
    for name, total_bytes, total_objects, error in results:
        if error:
            print(f"{name:<{name_width}}  {'ERROR: ' + error:>12}  {'-':>10}")
            continue
        grand_total_bytes += total_bytes
        print(f"{name:<{name_width}}  {human_readable(total_bytes):>12}  {total_objects:>10}")

    print("-" * (name_width + 28))
    print(f"{'TOTAL':<{name_width}}  {human_readable(grand_total_bytes):>12}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
