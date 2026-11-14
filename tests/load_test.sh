#!/usr/bin/env bash
# Demonstrates autoscaling of the public MapServer.
#   ./tests/load_test.sh eu-north-1 [requests-per-minute] [minutes]
# Sends steady traffic above the scaling threshold and reports the number of
# MapServer tasks every 30 seconds. Passes when a second task is running.

# shellcheck source-path=SCRIPTDIR source=../scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

RATE="${2:-900}"
MINUTES="${3:-8}"

tf_init >/dev/null
out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
URL="$(out mapserver_url)"
CLUSTER="$(out ecs_cluster)"
SERVICE="$(out mapserver_service)"

running_tasks() {
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text
}

START_TASKS="$(running_tasks)"
echo "==> $RATE requests/minute for up to $MINUTES minutes against $URL"
echo "    MapServer tasks at start: $START_TASKS"

# Background load: RATE/60 requests each second, 20 at a time.
PER_SECOND=$((RATE / 60))
(
  END=$(( $(date +%s) + MINUTES * 60 ))
  while [[ "$(date +%s)" -lt "$END" ]]; do
    seq "$PER_SECOND" | xargs -P 20 -I{} curl -s -o /dev/null --max-time 10 "$URL" || true
    sleep 1
  done
) &
LOAD_PID=$!
trap 'kill "$LOAD_PID" 2>/dev/null || true' EXIT

SCALED=0
for _ in $(seq $((MINUTES * 2))); do
  sleep 30
  NOW="$(running_tasks)"
  echo "    $(date +%H:%M:%S)  running tasks: $NOW"
  if [[ "$NOW" -gt "$START_TASKS" ]]; then SCALED=1; break; fi
done

if [[ "$SCALED" == "1" ]]; then
  echo "PASS  autoscaling started another MapServer task under load"
else
  echo "FAIL  no additional task started within $MINUTES minutes"
  exit 1
fi
