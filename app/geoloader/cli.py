"""Load one local GeoJSON file: the same validation and loading as the Lambda
handler, without S3. Used where there is no S3 trigger (local Kubernetes).

    python -m geoloader.cli /data/valid.geojson
"""

from __future__ import annotations

import sys
from pathlib import Path

from . import db
from .handler import log, measure
from .validation import GeoJSONError, parse_features


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = Path(argv[1])
    body = path.read_bytes()
    try:
        features = parse_features(body)
    except GeoJSONError as exc:
        log("file_rejected", key=path.name, reason=str(exc))
        return 1

    with db.connect() as conn:
        postgis_version = db.ensure_schema(conn)
        rows = db.load_features(conn, path.name, features)
    log("file_loaded", key=path.name, rows=rows, postgis_version=postgis_version)
    measure(path.name, body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
