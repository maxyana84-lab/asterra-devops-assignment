#!/usr/bin/env bash
# Runs the whole stack in a local Kubernetes cluster (kind) and tests it.
#   ./k8s/deploy-local.sh           create the cluster, deploy, test
#   ./k8s/deploy-local.sh --delete  remove the cluster
# Needs only docker, kind and kubectl. Nothing is created in AWS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=asterra
NS=asterra
K="kubectl --context kind-$CLUSTER"

if [[ "${1:-}" == "--delete" ]]; then
  kind delete cluster --name "$CLUSTER"
  exit 0
fi

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

echo "==> Cluster"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config "$REPO_ROOT/k8s/kind-cluster.yaml" --wait 120s
fi

echo "==> Images"
docker build -q -t asterra-geoloader:local "$REPO_ROOT/app" >/dev/null
docker build -q -t asterra-gdal:local "$REPO_ROOT/services/gdal" >/dev/null
docker build -q -t asterra-mapserver:local "$REPO_ROOT/services/mapserver" >/dev/null
kind load docker-image --name "$CLUSTER" \
  asterra-geoloader:local asterra-gdal:local asterra-mapserver:local

echo "==> Deploy"
$K apply -f "$REPO_ROOT/k8s/manifests/00-namespace.yaml"
# The database password is generated here, once, and kept only in the cluster.
if ! $K -n "$NS" get secret postgis-credentials >/dev/null 2>&1; then
  $K -n "$NS" create secret generic postgis-credentials \
    --from-literal=username=geoadmin \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
fi
$K -n "$NS" create configmap geojson-samples --from-file="$REPO_ROOT/app/samples" \
  --dry-run=client -o yaml | $K apply -f -
$K -n "$NS" delete job geoloader --ignore-not-found >/dev/null # Jobs are immutable: re-run from scratch
$K apply -f "$REPO_ROOT/k8s/manifests/"

echo "==> Wait"
$K -n "$NS" rollout status statefulset/postgis --timeout=180s
$K -n "$NS" rollout status deployment/gdal --timeout=180s
$K -n "$NS" rollout status deployment/mapserver --timeout=180s
$K -n "$NS" wait --for=condition=complete job/geoloader --timeout=180s || true

echo "==> Test"
psql() { $K -n "$NS" exec postgis-0 -- sh -c "psql -U \"\$POSTGRES_USER\" -d geodata -Atc \"$1\""; }

POSTGIS="$(psql 'SELECT postgis_version()' 2>/dev/null || true)"
if [[ -n "$POSTGIS" ]]; then pass "PostGIS is enabled ($POSTGIS)"; else fail "PostGIS is enabled"; fi

ROWS="$(psql "SELECT count(*) FROM geo_features WHERE source_key = 'valid.geojson'" 2>/dev/null || true)"
if [[ "$ROWS" == "3" ]]; then pass "loader Job put 3 features into PostGIS"; else fail "loader Job put 3 features into PostGIS (got '$ROWS')"; fi

if $K -n "$NS" logs job/geoloader | grep -q '"event": "file_stats"'; then
  pass "loader reached the private GDAL service (area and length logged)"
else
  fail "loader reached the private GDAL service"; $K -n "$NS" logs job/geoloader | tail -5
fi

CAPS_URL="http://127.0.0.1:8088/?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities"
if curl -s --retry 10 --retry-delay 2 --retry-all-errors --max-time 10 "$CAPS_URL" | grep -q "<Name>areas</Name>"; then
  pass "MapServer answers on the published port 8088"
else
  fail "MapServer answers on the published port 8088"
fi

# Network policies: a pod outside the namespace must not reach the private services.
probe() { # probe <namespace> <host> <port> -> succeeds if a TCP connection opens
  $K -n "$1" run "probe-$RANDOM" --rm -i --restart=Never --quiet --image=busybox:1.36 \
    --command -- sh -c "nc -z -w 3 $2 $3" >/dev/null 2>&1
}
if probe default "gdal.$NS.svc.cluster.local" 8080; then
  fail "GDAL service is closed to other namespaces"
else
  pass "GDAL service is closed to other namespaces"
fi
if probe default "postgis.$NS.svc.cluster.local" 5432; then
  fail "database is closed to other namespaces"
else
  pass "database is closed to other namespaces"
fi
if probe "$NS" gdal 8080; then
  pass "GDAL service is open inside its namespace"
else
  fail "GDAL service is open inside its namespace"
fi
if probe "$NS" postgis 5432; then
  fail "database is closed to pods that are not the loader"
else
  pass "database is closed to pods that are not the loader"
fi

$K -n "$NS" get pods,svc
if [[ "$FAILED" == "0" ]]; then echo "==> All checks passed"; else echo "==> Some checks FAILED"; exit 1; fi
