#!/usr/bin/env bash
# End-to-end test against a deployed environment.
#   ./tests/smoke_test.sh eu-north-1
# Uploads one valid and one invalid GeoJSON file and checks that the valid one
# reaches the PostGIS table, the invalid one is rejected, and both are logged.

# shellcheck source-path=SCRIPTDIR source=../scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

tf_init >/dev/null
out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
BUCKET="$(out ingest_bucket)"
FUNCTION="$(out geoloader_function)"
LOG_GROUP="$(out geoloader_log_group)"

RUN_ID="smoke-$(date +%s)"
VALID_KEY="$RUN_ID/valid.geojson"
INVALID_KEY="$RUN_ID/invalid.geojson"
START_MS="$(($(date +%s) * 1000))"
FAILED=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

invoke() { # invoke <json payload> -> prints the function's JSON response
  local response; response="$(mktemp)"
  aws lambda invoke --function-name "$FUNCTION" --cli-binary-format raw-in-base64-out \
    --payload "$1" "$response" >/dev/null
  cat "$response"; rm -f "$response"
}

rows_for() { invoke "{\"action\":\"stats\",\"source_key\":\"$1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("rows", "error"))'; }

logged() { # logged <event> <key> -> succeeds if such a log line exists
  local count
  count="$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$START_MS" \
    --filter-pattern "{ \$.event = \"$1\" && \$.key = \"$2\" }" \
    --query 'length(events)' --output text)"
  [[ "$count" != "0" && "$count" != "None" ]]
}

wait_for() { # wait_for <description> <command...>: retry for up to 90 seconds
  local description="$1"; shift
  for _ in $(seq 1 18); do
    if "$@"; then pass "$description"; return; fi
    sleep 5
  done
  fail "$description"
}

echo "==> Smoke test in $REGION, run $RUN_ID"

POSTGIS="$(invoke '{"action":"init_db"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("postgis_version", ""))')"
if [[ -n "$POSTGIS" ]]; then pass "PostGIS is enabled ($POSTGIS)"; else fail "PostGIS is enabled"; fi

aws s3 cp --only-show-errors "$REPO_ROOT/app/samples/valid.geojson" "s3://$BUCKET/$VALID_KEY"
aws s3 cp --only-show-errors "$REPO_ROOT/app/samples/invalid.geojson" "s3://$BUCKET/$INVALID_KEY"

valid_loaded() { [[ "$(rows_for "$VALID_KEY")" == "3" ]]; }
wait_for "valid file: 3 features loaded into PostGIS" valid_loaded
wait_for "valid file: 'file_loaded' is in CloudWatch Logs" logged file_loaded "$VALID_KEY"
wait_for "invalid file: 'file_rejected' is in CloudWatch Logs" logged file_rejected "$INVALID_KEY"

if [[ "$(rows_for "$INVALID_KEY")" == "0" ]]; then
  pass "invalid file: nothing loaded"
else
  fail "invalid file: nothing loaded"
fi

if curl -s -o /dev/null --max-time 10 -w '%{http_code}' \
     "https://$BUCKET.s3.$REGION.amazonaws.com/$VALID_KEY" | grep -q '^403$'; then
  pass "ingest bucket refuses anonymous access"
else
  fail "ingest bucket refuses anonymous access"
fi

# ---------- Private GDAL + GeoPandas service ----------
# It has no public address, so it is tested through its only client: the loader
# calls it after each load and logs what it returned.
stats_logged() {
  aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$START_MS" \
    --filter-pattern "{ \$.event = \"file_stats\" && \$.key = \"$VALID_KEY\" && \$.area_m2 > 1000000 && \$.gdal_driver = \"GeoJSON\" }" \
    --query 'length(events)' --output text | grep -qvE '^(0|None)$'
}
wait_for "private GDAL service measured the file (area and length logged)" stats_logged

# ---------- Public MapServer on the Elastic IPs ----------
WMS="SERVICE=WMS&VERSION=1.3.0"
GETMAP="$WMS&REQUEST=GetMap&LAYERS=areas,pipes,sites&STYLES=&CRS=CRS:84&BBOX=34.86,32.14,34.96,32.21&WIDTH=800&HEIGHT=560&FORMAT=image/png"
PUBLIC_IPS="$(terraform -chdir="$TF_DIR" output -json public_ips | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')"
GDAL_PORT="$(out gdal_service_url | sed -E 's#.*:([0-9]+)$#\1#')"

for ip in $PUBLIC_IPS; do
  caps_ok() { curl -s --max-time 10 "http://$ip/?$WMS&REQUEST=GetCapabilities" | grep -q "<Name>areas</Name>"; }
  wait_for "MapServer on Elastic IP $ip: WMS capabilities list the layers" caps_ok

  if [[ "$(curl -s --max-time 15 -o /dev/null -w '%{content_type}' "http://$ip/?$GETMAP")" == image/png* ]]; then
    pass "MapServer on Elastic IP $ip: GetMap renders a PNG"
  else
    fail "MapServer on Elastic IP $ip: GetMap renders a PNG"
  fi

  if curl -s --max-time 5 -o /dev/null "http://$ip:$GDAL_PORT/health"; then
    fail "container port $GDAL_PORT is closed on public address $ip"
  else
    pass "container port $GDAL_PORT is closed on public address $ip"
  fi
done

aws s3 rm --only-show-errors --recursive "s3://$BUCKET/$RUN_ID/"

if [[ "$FAILED" == "0" ]]; then echo "==> All checks passed"; else echo "==> Some checks FAILED"; exit 1; fi
