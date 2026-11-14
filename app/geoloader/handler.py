"""AWS Lambda entry point.

Handles three kinds of events:
  * S3 "object created" notifications: validate the GeoJSON file and load it.
  * {"action": "init_db"}: enable PostGIS and create the table (called by Terraform).
  * {"action": "stats", "source_key": "..."}: row count, used by the smoke test.

Everything is logged as one JSON object per line, which CloudWatch Logs can query.
"""

from __future__ import annotations

import json
import os
import sys
import time
from functools import lru_cache
from pathlib import Path
from urllib.parse import unquote_plus

import boto3

from . import db
from .validation import GeoJSONError, parse_features

MAX_FILE_BYTES = int(os.environ.get("MAX_FILE_BYTES", str(50 * 1024 * 1024)))
VERSION = (Path(__file__).parent.parent / "VERSION").read_text().strip()


def log(event: str, **fields) -> None:
    print(json.dumps({"event": event, "version": VERSION, **fields}, default=str), file=sys.stdout)


@lru_cache(maxsize=1)
def _s3():
    return boto3.client("s3")


def handler(event: dict, context=None) -> dict:
    action = event.get("action")
    if action == "init_db":
        return init_db()
    if action == "stats":
        return stats(event.get("source_key"))

    results = [process_record(record) for record in event.get("Records", [])]
    return {"results": results}


def init_db() -> dict:
    with db.connect() as conn:
        postgis_version = db.ensure_schema(conn)
    log("db_initialised", postgis_version=postgis_version)
    return {"status": "ok", "version": VERSION, "postgis_version": postgis_version}


def stats(source_key: str | None) -> dict:
    with db.connect() as conn:
        return {"status": "ok", "source_key": source_key, "rows": db.count_rows(conn, source_key)}


def process_record(record: dict) -> dict:
    """Validate and load one S3 object.

    A bad file is logged and skipped (retrying would not fix it).
    An infrastructure error is raised, so Lambda retries the event.
    """
    bucket = record["s3"]["bucket"]["name"]
    # Keys arrive URL-encoded in S3 events ("my file.geojson" -> "my+file.geojson").
    key = unquote_plus(record["s3"]["object"]["key"])
    size = record["s3"]["object"].get("size", 0)
    started = time.monotonic()
    log("file_received", bucket=bucket, key=key, size=size)

    if size > MAX_FILE_BYTES:
        return _reject(bucket, key, f"file is {size} bytes, limit is {MAX_FILE_BYTES}")

    body = _s3().get_object(Bucket=bucket, Key=key)["Body"].read()
    try:
        features = parse_features(body)
    except GeoJSONError as exc:
        return _reject(bucket, key, str(exc))
    log("file_valid", bucket=bucket, key=key, features=len(features))

    try:
        with db.connect() as conn:
            rows = db.load_features(conn, key, features)
    except Exception as exc:
        log("load_failed", bucket=bucket, key=key, error=repr(exc))
        raise

    duration_ms = round((time.monotonic() - started) * 1000)
    log("file_loaded", bucket=bucket, key=key, rows=rows, duration_ms=duration_ms)
    return {"key": key, "status": "loaded", "rows": rows}


def _reject(bucket: str, key: str, reason: str) -> dict:
    log("file_rejected", bucket=bucket, key=key, reason=reason)
    return {"key": key, "status": "rejected", "reason": reason}
