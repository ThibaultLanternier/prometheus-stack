# Design

## Context

This is a greenfield project: the directory holds only OpenSpec scaffolding. See proposal.md for why, and the `monitoring-stack` and `metrics-backfill` specs for the required behavior. The host runs Linux with Docker 29 and Compose v5. The data to load will be OpenMetrics text files, which the user will write later. Their sampling interval is not known yet, so query lookback must stay tunable.

Prometheus facts that shape this design:
- The `prom/prometheus` image is busybox-based. It ships `promtool`, `sh`, `awk` and `wget`, and runs as `nobody` (uid/gid 65534).
- `promtool tsdb create-blocks-from openmetrics <file> <outdir>` requires second-precision timestamps and a trailing `# EOF`. It accepts millisecond timestamps without complaint and silently stores them at far-future dates.
- Prometheus loads only directories whose names are valid ULIDs. Other directories in the data dir are ignored. The running TSDB rescans the data dir for new blocks on its periodic reload (about every minute).
- The default retention (15d) would delete backfilled history.

## Goals / Non-Goals

**Goals:**
- One `docker compose up -d` brings up a working, provisioned stack.
- One `docker compose run --rm importer` imports every pending file, safely, while the stack is running.
- An automated smoke test proves the full path, from file to Prometheus query to Grafana datasource, without touching the user's real data.

**Non-Goals:**
- Converting CSV, JSON or databases into OpenMetrics.
- Live scraping of external targets. Prometheus scrapes only itself.
- Alerting, Alertmanager, remote storage, auth or TLS. The stack is local only.
- Deleting or re-importing already imported data. That is done manually with the TSDB admin API if ever needed.

## Decisions

### D1. Repository layout
```
docker-compose.yml
.env.example                 # PROMETHEUS_RETENTION, PROMETHEUS_LOOKBACK_DELTA,
                             # GF_ADMIN_USER/PASSWORD, ports, IMPORT_DIR
prometheus/prometheus.yml    # self-scrape only
grafana/provisioning/datasources/prometheus.yml
grafana/provisioning/dashboards/dashboards.yml
grafana/dashboards/sample.json
import/                      # drop zone (.gitkeep); *.om git-ignored
import/processed/ import/failed/   # committed with .gitkeep
examples/sample.om           # documented sample data
scripts/import.sh            # importer logic (runs inside container)
scripts/smoke-test.sh        # end-to-end verification (runs on host)
README.md                    # usage + file format reference
```
The sample lives in `examples/`, not `import/`, so it is never imported by accident. The user copies it into `import/` to try the stack out.

### D2. Importer is a profiled compose service that reuses the Prometheus image
The `importer` service uses the same pinned `prom/prometheus` tag, with `profiles: [import]`, `entrypoint: ["/bin/sh", "/scripts/import.sh"]`, and these mounts: the `prometheus-data` volume at `/prometheus`, `${IMPORT_DIR:-./import}` at `/import`, and `./scripts` read-only.

The profile keeps the importer out of `docker compose up`. Reusing the image guarantees that the `promtool` version matches the server.

*Alternatives:* a host script calling `docker run`, which duplicates compose's volume and network wiring; or a long-running watcher that polls the folder, which adds a moving part for no gain with occasional manual imports.

### D3. Validate each file before running promtool
`import.sh` runs a single `awk` pass per file and rejects it if:
- the last non-empty line is not `# EOF`, or
- any sample timestamp is greater than now + 1 day, or `>= 1e11`. This catches millisecond timestamps, which promtool would otherwise accept.

promtool's own parser then catches syntax errors. Doing this check in the importer is the only way to meet the spec's "ms timestamps rejected" scenario.

### D4. Atomic hand-off through staging inside the same volume
For each file, promtool writes into `/prometheus/.staging/<run-id>/`. Prometheus ignores that directory because its name is not a ULID.

On success, each block directory is `chown`ed to 65534:65534 and `mv`ed into `/prometheus/`. Staging and target are on the same filesystem, so the rename is atomic and Prometheus never sees a half-written block. On failure the staging dir is deleted.

Leftover `.staging` dirs from killed runs are removed when the next import starts.

*Alternative:* writing straight into `/prometheus/`. It is simpler, but a kill mid-write could leave a broken ULID directory that Prometheus refuses to load.

### D5. The importer runs as root, the server as nobody
The `./import` bind mount belongs to the host user (uid 1000), so a `nobody` container cannot move files in it. The importer therefore runs as `user: "0:0"`:
- It `chown`s new blocks to 65534 (D4), so Prometheus can later compact and delete them.
- `processed/` and `failed/` are committed directories owned by the host user. `mv` keeps each file's original owner, so the host user still owns their files afterwards.

*Alternative:* running both services as the host UID. That fights the image's volume ownership and makes the named volume UID-specific.

### D6. Prometheus flags through compose `command`
`--config.file=/etc/prometheus/prometheus.yml`, `--storage.tsdb.path=/prometheus`, `--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-10y}`, `--query.lookback-delta=${PROMETHEUS_LOOKBACK_DELTA:-5m}`, `--web.enable-lifecycle`.

Overriding `command` replaces the image defaults, so the config and storage paths are restated explicitly.

### D7. Grafana provisioning with a fixed datasource UID
The datasource has `uid: prometheus`, `url: http://prometheus:9090` and is marked as default. The dashboard JSON refers to that UID, so provisioning does not depend on generated IDs.

The sample dashboard has a fixed time range matching `examples/sample.om`, which covers one day in early 2024 at 5-minute steps. That range is older than 15 days, so the sample also exercises the retention setting.

Credentials come from `GF_SECURITY_ADMIN_USER/PASSWORD` in `.env`. Anonymous access is off. Grafana state lives in the `grafana-data` volume.

### D8. Exposure, health and versions
Ports are published as `127.0.0.1:${PROMETHEUS_PORT:-9090}:9090` and `127.0.0.1:${GRAFANA_PORT:-3000}:3000`.

Healthchecks:
- Prometheus: `wget -qO- localhost:9090/-/ready`.
- Grafana: `/api/health` using whichever HTTP client the pinned image provides.

Grafana has `depends_on: prometheus (service_healthy)`. Image tags are pinned to the current stable releases at implementation time, never `latest`.

### D9. Smoke test isolated from the user's data
`scripts/smoke-test.sh` runs the stack under a separate compose project (`-p prom-smoke`). It uses alternative ports and a temporary `IMPORT_DIR`. It copies the sample file, one file without `# EOF` and one with millisecond timestamps into that dir, then runs the importer and asserts:
- the exit code is non-zero, because two files fail;
- each file ended up in the expected `processed/` or `failed/` folder;
- an instant query at a sample timestamp returns the sample value within 120 s;
- Grafana's datasource health endpoint reports OK;
- a second import run imports nothing.

It always runs `down -v` on exit. This script is the project's test suite. Shell linting uses `shellcheck`, run through its container image, plus `docker compose config -q` and `promtool check config`.

## Risks / Trade-offs

- [The periodic block reload may be slower than expected or behave differently across versions] → The smoke test checks the 2-minute bound. If it fails, the importer prints a hint, and the README documents `docker compose restart prometheus` as a fallback.
- [Overlapping blocks after importing overlapping time ranges] → Recent Prometheus versions merge overlaps during compaction. The `processed/` folder prevents accidental re-imports.
- [Sparse data looks empty in Grafana] → `PROMETHEUS_LOOKBACK_DELTA` is in `.env`, the README explains it, and `last_over_time()` is shown as a per-query alternative.
- [Root importer container] → It runs only on demand, with access limited to the data volume, the import dir and read-only scripts.
- [Many small 2h blocks from multi-year imports] → This is acceptable for local use, and Prometheus compacts them over time. `--max-block-duration` can be added later without changing the specs.
- [Huge files take a long time] → They are processed sequentially. Throughput is promtool's, and no extra tuning is in scope.

## Migration Plan

Not applicable: this is a new project with no existing deployment. To roll back, run `docker compose down -v`.
