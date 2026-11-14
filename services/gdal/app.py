"""Private geoprocessing microservice: GDAL + GeoPandas behind a small HTTP API.

  GET  /health  -> library versions
  POST /stats   -> body is a GeoJSON document; returns feature count, geometry
                   types, bounding box, total area and total length

Non-interactive: no UI, no state, one JSON log line per request on stdout.
Uses only the standard library for HTTP, so the image carries no web framework.
"""

from __future__ import annotations

import io
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import geopandas
from osgeo import gdal

gdal.UseExceptions()

PORT = int(os.environ.get("PORT", "8080"))
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(50 * 1024 * 1024)))
VERSION = os.environ.get("SERVICE_VERSION", "dev")
# Equal-area projection, so areas and lengths come out in metres anywhere on Earth.
METRIC_CRS = "EPSG:6933"


def log(event: str, **fields) -> None:
    print(json.dumps({"event": event, "version": VERSION, **fields}, default=str), flush=True)


def describe_with_gdal(body: bytes) -> dict:
    """Open the document with GDAL itself: which driver reads it, and how many layers."""
    path = f"/vsimem/{uuid.uuid4().hex}.geojson"
    gdal.FileFromMemBuffer(path, body)
    try:
        dataset = gdal.OpenEx(path, gdal.OF_VECTOR)
        return {"driver": dataset.GetDriver().ShortName, "layers": dataset.GetLayerCount()}
    finally:
        gdal.Unlink(path)


def compute_stats(body: bytes) -> dict:
    described = describe_with_gdal(body)
    frame = geopandas.read_file(io.BytesIO(body))
    if frame.crs is None:
        frame = frame.set_crs("EPSG:4326")  # GeoJSON is WGS 84 by definition

    with_geometry = frame[frame.geometry.notna() & ~frame.geometry.is_empty]
    metric = with_geometry.to_crs(METRIC_CRS)
    kinds = metric.geometry.geom_type
    polygons = metric[kinds.isin(["Polygon", "MultiPolygon"])]
    lines = metric[kinds.isin(["LineString", "MultiLineString"])]

    return {
        "gdal_driver": described["driver"],
        "layers": described["layers"],
        "features": int(len(frame)),
        "geometry_types": {
            k: int(v) for k, v in with_geometry.geometry.geom_type.value_counts().items()
        },
        "bbox": [round(float(v), 6) for v in with_geometry.total_bounds]
        if len(with_geometry)
        else None,
        "area_m2": round(float(polygons.geometry.area.sum()), 1),
        "length_m": round(float(lines.geometry.length.sum()), 1),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "asterra-gdal"

    def log_message(self, *args) -> None:  # replaced by the JSON log lines below
        pass

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - name required by http.server
        if self.path != "/health":
            self._send(404, {"error": "not found"})
            return
        self._send(
            200,
            {
                "status": "ok",
                "version": VERSION,
                "gdal": gdal.__version__,
                "geopandas": geopandas.__version__,
            },
        )

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/stats":
            self._send(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(413, {"error": f"body must be 1..{MAX_BODY_BYTES} bytes"})
            return

        started = time.monotonic()
        body = self.rfile.read(length)
        try:
            stats = compute_stats(body)
        except Exception as exc:  # unreadable input is the caller's error, not a crash
            log("stats_failed", bytes=length, error=repr(exc))
            self._send(422, {"error": f"cannot process the document: {exc}"})
            return

        log("stats", bytes=length, duration_ms=round((time.monotonic() - started) * 1000), **stats)
        self._send(200, stats)


def main() -> None:
    log("starting", port=PORT, gdal=gdal.__version__, geopandas=geopandas.__version__)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 - container port
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
