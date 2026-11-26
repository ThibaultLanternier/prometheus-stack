#!/usr/bin/env bash
# End-to-end smoke test: start an isolated copy of the stack, import the sample
# file plus two invalid files, and check the data is queryable through
# Prometheus, that Loki becomes ready and that both Grafana datasources work.
#
# Runs on the host. Uses its own compose project, ports and import folder, and
# ignores .env, so it never touches the stack you use day to day. Everything it
# creates is removed on exit.
#
# Usage: scripts/smoke-test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=prom-smoke
QUERY_TIMEOUT=120
LOKI_TIMEOUT=60
# A known point of examples/sample.om: bedroom at 2024-01-15T12:00:00Z is 20.0
QUERY='room_temperature_celsius{room="bedroom"}'
QUERY_TIME=1705320000
EXPECTED=20

export PROMETHEUS_PORT=${SMOKE_PROMETHEUS_PORT:-19090}
export GRAFANA_PORT=${SMOKE_GRAFANA_PORT:-13000}
export LOKI_PORT=${SMOKE_LOKI_PORT:-13100}
export LOKI_RETENTION=10y
export PROMETHEUS_RETENTION=10y
export PROMETHEUS_LOOKBACK_DELTA=5m
export GF_SECURITY_ADMIN_USER=admin
export GF_SECURITY_ADMIN_PASSWORD=smoke-test

# Inside the repo rather than /tmp, so the Docker daemon can always mount it.
WORK=$(mktemp -d "$ROOT/.smoke.XXXXXX")
export IMPORT_DIR="$WORK/import"
mkdir -p "$IMPORT_DIR"
: >"$WORK/empty.env"

compose() {
    docker compose -p "$PROJECT" --project-directory "$ROOT" \
        -f "$ROOT/docker-compose.yml" --env-file "$WORK/empty.env" "$@"
}

cleanup() {
    compose --profile import down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

echo "== Starting stack (project $PROJECT, ports $PROMETHEUS_PORT/$GRAFANA_PORT/$LOKI_PORT)"
compose up -d --wait

echo "== Preparing fixtures"
cp "$ROOT/examples/sample.om" "$IMPORT_DIR/good.om"
sed '$d' "$ROOT/examples/sample.om" >"$IMPORT_DIR/no-eof.om"
sed -E 's/ ([0-9]{10})$/ \1000/' "$ROOT/examples/sample.om" >"$IMPORT_DIR/ms-timestamps.om"

echo "== First import (2 of 3 files must fail)"
set +e
compose run --rm -T importer
import_status=$?
set -e

echo "== Checking results"
check "importer exits non-zero when a file fails" test "$import_status" -ne 0
check "valid file moved to processed/" test -f "$IMPORT_DIR/processed/good.om"
check "file without # EOF moved to failed/" test -f "$IMPORT_DIR/failed/no-eof.om"
check "file with ms timestamps moved to failed/" test -f "$IMPORT_DIR/failed/ms-timestamps.om"
check "no file left in the import folder" \
    test -z "$(find "$IMPORT_DIR" -maxdepth 1 -name '*.om')"

query_value() {
    curl -sf "http://localhost:$PROMETHEUS_PORT/api/v1/query" \
        --data-urlencode "query=$QUERY" --data-urlencode "time=$QUERY_TIME" |
        sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
}
wait_for_data() {
    local deadline=$((SECONDS + QUERY_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(query_value)" = "$EXPECTED" ] && return 0
        sleep 5
    done
    return 1
}
start=$SECONDS
if wait_for_data; then
    pass "imported value queryable after $((SECONDS - start))s (limit ${QUERY_TIMEOUT}s)"
else
    fail "imported value not queryable within ${QUERY_TIMEOUT}s (got '$(query_value)')"
fi

grafana_health() { # grafana_health DATASOURCE_UID
    curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
        "http://localhost:$GRAFANA_PORT/api/datasources/uid/$1/health" |
        grep -q '"status":"OK"'
}
check "Grafana Prometheus datasource health is OK" grafana_health prometheus

# Loki has no compose healthcheck (no HTTP client in its image), so
# `up --wait` only waits for it to start: poll its readiness endpoint.
loki_ready() {
    [ "$(curl -s "http://localhost:$LOKI_PORT/ready")" = "ready" ]
}
wait_for_loki() {
    local deadline=$((SECONDS + LOKI_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        loki_ready && return 0
        sleep 2
    done
    return 1
}
if wait_for_loki; then
    pass "Loki ready (limit ${LOKI_TIMEOUT}s)"
else
    fail "Loki not ready within ${LOKI_TIMEOUT}s"
fi
check "Grafana Loki datasource health is OK" grafana_health loki

echo "== Second import (nothing left to do)"
second=$(compose run --rm -T importer 2>&1) && second_status=0 || second_status=$?
echo "$second"
check "second run exits 0" test "$second_status" -eq 0
check "second run imports nothing" grep -q 'Nothing to import' <<<"$second"

echo
if [ "$failures" -eq 0 ]; then
    echo "Smoke test passed."
else
    echo "Smoke test FAILED: $failures check(s) failed."
    exit 1
fi
