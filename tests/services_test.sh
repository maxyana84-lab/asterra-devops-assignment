#!/usr/bin/env bash
# Builds the two service images and tests them locally with Docker. No AWS needed.
#   ./tests/services_test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

cleanup() { docker rm -f asterra-test-gdal asterra-test-mapserver >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

wait_http() { # wait_http <url>: wait up to 60 s for an HTTP 200
  for _ in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == "200" ]]; then return 0; fi
    sleep 2
  done
  return 1
}

echo "==> GDAL + GeoPandas service"
docker build -q -t asterra-test-gdal "$REPO_ROOT/services/gdal" >/dev/null
docker run -d --name asterra-test-gdal -p 127.0.0.1:18080:8080 asterra-test-gdal >/dev/null

if wait_http "http://127.0.0.1:18080/health"; then
  HEALTH="$(curl -s http://127.0.0.1:18080/health)"
  pass "/health answers: $HEALTH"
else
  fail "/health answers"; docker logs asterra-test-gdal | tail -20
fi

STATS="$(curl -s -X POST --data-binary "@$REPO_ROOT/app/samples/valid.geojson" http://127.0.0.1:18080/stats)"
if python3 - "$STATS" <<'PY'
import json, sys
stats = json.loads(sys.argv[1])
assert stats["features"] == 3, stats
assert stats["gdal_driver"] == "GeoJSON", stats
assert stats["geometry_types"] == {"Point": 1, "LineString": 1, "Polygon": 1}, stats
assert 11_000_000 < stats["area_m2"] < 14_000_000, stats   # about 3.8 km x 3.3 km
assert 2_000 < stats["length_m"] < 4_000, stats
PY
then pass "/stats computes area and length: $STATS"; else fail "/stats computes area and length: $STATS"; fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'not geojson' http://127.0.0.1:18080/stats)"
if [[ "$CODE" == "422" ]]; then pass "/stats rejects garbage with 422"; else fail "/stats rejects garbage with 422 (got $CODE)"; fi

if [[ "$(docker exec asterra-test-gdal id -u)" != "0" ]]; then pass "runs as a non-root user"; else fail "runs as a non-root user"; fi

echo "==> MapServer"
docker build -q -t asterra-test-mapserver "$REPO_ROOT/services/mapserver" >/dev/null
docker run -d --name asterra-test-mapserver -p 127.0.0.1:18081:8080 asterra-test-mapserver >/dev/null
BASE="http://127.0.0.1:18081/?SERVICE=WMS&VERSION=1.3.0"

if wait_http "$BASE&REQUEST=GetCapabilities"; then
  CAPS="$(curl -s "$BASE&REQUEST=GetCapabilities")"
  if grep -q "<Name>areas</Name>" <<<"$CAPS" && grep -q "<Name>pipes</Name>" <<<"$CAPS" \
     && grep -q "<Name>sites</Name>" <<<"$CAPS"; then
    pass "WMS GetCapabilities lists the three layers"
  else
    fail "WMS GetCapabilities lists the three layers"
  fi
else
  fail "WMS GetCapabilities answers"; docker logs asterra-test-mapserver 2>&1 | tail -20
fi

MAP_URL="$BASE&REQUEST=GetMap&LAYERS=areas,pipes,sites&STYLES=&CRS=CRS:84&BBOX=34.86,32.14,34.96,32.21&WIDTH=800&HEIGHT=560&FORMAT=image/png"
TMP_PNG="$(mktemp)"
TYPE="$(curl -s -o "$TMP_PNG" -w '%{content_type}' "$MAP_URL")"
SIZE="$(stat -c %s "$TMP_PNG")"
if [[ "$TYPE" == image/png* && "$SIZE" -gt 2000 ]]; then
  pass "WMS GetMap renders a PNG ($SIZE bytes)"
else
  fail "WMS GetMap renders a PNG (type '$TYPE', $SIZE bytes)"; head -c 600 "$TMP_PNG"; echo
fi
rm -f "$TMP_PNG"

if [[ "$FAILED" == "0" ]]; then echo "==> All checks passed"; else echo "==> Some checks FAILED"; exit 1; fi
