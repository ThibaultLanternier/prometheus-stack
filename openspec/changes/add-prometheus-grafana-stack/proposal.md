# Proposal

## Why

I want to explore my own time-series data locally with Prometheus and Grafana. That data exists as flat files, not as live scrape targets. Prometheus has no import button, so the project needs a repeatable, documented way to start the stack and backfill those files. Without it, every attempt means rediscovering promtool flags, retention traps and timestamp-unit pitfalls.

## What Changes

- Add a Docker Compose stack that runs Prometheus and Grafana locally. It persists data in named volumes and exposes the UIs on localhost only.
- Configure Prometheus to keep historical data. Retention is long, and both retention and query lookback are configurable through `.env`, so backfilled samples are not deleted and sparse series render correctly.
- Provision Grafana automatically with a Prometheus datasource, plus an example dashboard that displays imported data.
- Add an on-demand importer. It turns OpenMetrics text files dropped in `./import/` into TSDB blocks with `promtool tsdb create-blocks-from openmetrics` and hands them to the running Prometheus.
- Document the import file format (OpenMetrics, timestamps in seconds, `# EOF`, ordering, label guidance) and ship a sample file.
- Add a smoke test that proves the end-to-end path: stack up, import the sample, query the imported series through Prometheus and Grafana.

## Capabilities

### New Capabilities
- `monitoring-stack`: The local Prometheus + Grafana runtime. It covers startup, persistence, retention, query lookback, network exposure and Grafana provisioning.
- `metrics-backfill`: Importing historical time series from OpenMetrics text files into Prometheus. It covers the accepted file format, the import trigger, the handling of processed and invalid files, and when imported data becomes queryable.

### Modified Capabilities

None. The project has no existing specs.

## Impact

- New files at the repo root: `docker-compose.yml`, `.env.example`, `prometheus/`, `grafana/provisioning/`, `import/`, `scripts/` and `README.md`.
- Dependencies: Docker Engine and Docker Compose v2+ on the host. Container images are `prom/prometheus` (which provides `promtool`) and `grafana/grafana`, pinned to explicit tags.
- Host ports: 9090 (Prometheus) and 3000 (Grafana), bound to `127.0.0.1`.
- Converting other formats (CSV, databases) into OpenMetrics is out of scope. The user produces the files.
- The project directory is not yet a git repository. Version control must be initialised (with a `develop` branch and a remote) before implementation can follow the branch/PR workflow.
