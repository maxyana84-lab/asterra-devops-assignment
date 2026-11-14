"""PostGIS access: connection, schema and loading."""

from __future__ import annotations

import json
import os
from functools import lru_cache

import boto3
import psycopg
from psycopg.types.json import Jsonb

from .validation import Feature

SCHEMA_SQL = """
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS geo_features (
    id            bigserial PRIMARY KEY,
    source_key    text        NOT NULL,
    feature_index integer     NOT NULL,
    properties    jsonb       NOT NULL DEFAULT '{}'::jsonb,
    geom          geometry(Geometry, 4326),
    loaded_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_key, feature_index)
);

CREATE INDEX IF NOT EXISTS geo_features_geom_idx ON geo_features USING gist (geom);
"""

INSERT_SQL = """
INSERT INTO geo_features (source_key, feature_index, properties, geom)
VALUES (%s, %s, %s, ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))
"""


@lru_cache(maxsize=1)
def _credentials() -> dict:
    """Read the database username and password from Secrets Manager (once per container)."""
    client = boto3.client("secretsmanager")
    secret = client.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
    return json.loads(secret["SecretString"])


def connect() -> psycopg.Connection:
    creds = _credentials()
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=creds["username"],
        password=creds["password"],
        sslmode="require",
        connect_timeout=10,
    )


def ensure_schema(conn: psycopg.Connection) -> str:
    """Enable PostGIS and create the table if missing. Returns the PostGIS version."""
    conn.execute(SCHEMA_SQL)
    return conn.execute("SELECT postgis_version()").fetchone()[0]


def load_features(conn: psycopg.Connection, source_key: str, features: list[Feature]) -> int:
    """Replace everything previously loaded from source_key with these features.

    Runs in the caller's transaction, so a file is loaded completely or not at all,
    and uploading the same file twice does not duplicate rows.
    """
    rows = [
        (
            source_key,
            index,
            Jsonb(feature.properties),
            json.dumps(feature.geometry) if feature.geometry is not None else None,
        )
        for index, feature in enumerate(features)
    ]
    with conn.cursor() as cur:
        cur.execute("DELETE FROM geo_features WHERE source_key = %s", (source_key,))
        cur.executemany(INSERT_SQL, rows)
    return len(rows)


def count_rows(conn: psycopg.Connection, source_key: str | None) -> int:
    if source_key is None:
        return conn.execute("SELECT count(*) FROM geo_features").fetchone()[0]
    return conn.execute(
        "SELECT count(*) FROM geo_features WHERE source_key = %s", (source_key,)
    ).fetchone()[0]
