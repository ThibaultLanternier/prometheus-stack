# prometheus-stack

A local Prometheus + Grafana stack for exploring your own historical time series.
Data is not scraped: you write it as OpenMetrics text files and backfill them
into Prometheus with a single command.

## Requirements

- Docker Engine with Docker Compose v2 or later. Nothing else is needed on the host.

## Quick start

```sh
cp .env.example .env          # then set GF_SECURITY_ADMIN_PASSWORD
docker compose up -d
```

- Prometheus: <http://localhost:9090>
- Grafana: <http://localhost:3000> (log in with the credentials from `.env`)

Both ports are bound to `127.0.0.1` only, so other machines on your network
cannot reach them.

### Configuration (`.env`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `PROMETHEUS_PORT` | `9090` | Host port for Prometheus |
| `PROMETHEUS_RETENTION` | `10y` | How long samples are kept. Keep it long, or backfilled history gets deleted |
| `PROMETHEUS_LOOKBACK_DELTA` | `5m` | PromQL lookback window, see [Sparse data](#sparse-data-and-lookback) |
| `GRAFANA_PORT` | `3000` | Host port for Grafana |
| `GF_SECURITY_ADMIN_USER` | `admin` | Grafana admin user |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Grafana admin password |
| `IMPORT_DIR` | `./import` | Folder the importer reads from |

Grafana reads the admin credentials only when its data volume is first
created. To change them later, use the Grafana UI or reset the stack.

Run `docker compose up -d` again after changing `.env`.

## Import file format

The importer accepts [OpenMetrics](https://prometheus.io/docs/specs/om/open_metrics_spec/)
text files with the `.om` extension. A minimal valid file:

```text
# HELP house_power_watts Instantaneous power draw of the house.
# TYPE house_power_watts gauge
house_power_watts{meter="main"} 412.5 1704067200
house_power_watts{meter="main"} 398.0 1704067260
house_power_watts{meter="main"} 455.25 1704067320
# EOF
```

Each sample line is `metric_name{label="value",...} value timestamp`.

Rules:

- **Timestamps are Unix time in seconds.** Fractions are allowed (`1704067200.5`),
  milliseconds are not. A file with millisecond timestamps (e.g. `1704067200000`)
  or any timestamp more than one day in the future is rejected.
- **The last line must be `# EOF`.** A file without it is rejected.
- **Group lines by metric.** All lines for one metric come together, directly
  after its `# HELP` / `# TYPE` lines. A metric cannot reappear later in the file.
- **Timestamps go up.** Within each series (metric + label set), samples are in
  ascending time order.
- **Naming:** metric names use `[a-zA-Z_:][a-zA-Z0-9_:]*`. Include the unit as a
  suffix (`_celsius`, `_bytes`, `_seconds`, `_ratio`) and use base units.
  `# TYPE` should be `gauge` for measured values. Counter names must end in `_total`.
- **Labels describe identity, not values.** Use labels for things with a small,
  fixed set of values (`room`, `host`, `meter`). Never put timestamps, IDs or
  free text in labels: every distinct label combination creates a new series,
  and high cardinality makes Prometheus slow and memory-hungry.

See [`examples/sample.om`](examples/sample.om) for a complete example with
several series. It covers 2024-01-15 (UTC) at 5-minute steps and is shown by the
provisioned **Sample import** dashboard in Grafana.

### Sparse data and lookback

When a PromQL query evaluates a series at a given time, Prometheus uses the most
recent sample within the **lookback window** (5 minutes by default). If your
data is sampled less often than that, for example hourly, graphs show isolated
dots instead of lines.

Two fixes:

- Set `PROMETHEUS_LOOKBACK_DELTA` in `.env` to at least your sampling interval
  (e.g. `1h`), then run `docker compose up -d`.
- Or, per query, wrap the series: `last_over_time(my_metric[1h])`.

## Importing data

1. Put one or more `.om` files in `./import/` (or the folder set by `IMPORT_DIR`).
2. With the stack running, run:

   ```sh
   docker compose run --rm importer
   ```

To try it out with the bundled sample:

```sh
cp examples/sample.om import/
docker compose run --rm importer
```

Then open the **Sample import** dashboard in Grafana.

What happens:

- Every `.om` file in `./import/` is checked and converted with
  `promtool tsdb create-blocks-from openmetrics`. Prometheus and Grafana keep
  running throughout.
- Imported files move to `./import/processed/`, so running the importer again
  never imports them twice.
- Files that fail move to `./import/failed/`, and the reason is printed. The
  importer carries on with the remaining files, then exits with a non-zero
  status. A failed file adds no data. Fix it, move it back to `./import/` and
  run the importer again.
- With no pending files, it prints `Nothing to import` and exits successfully.
- If a file with the same name is already in `processed/` or `failed/`, the new
  one gets a timestamp prefix instead of overwriting it.

Imported data becomes queryable within about a minute, without a restart:
Prometheus picks up the new blocks on its periodic reload. If it does not show
up after two minutes, restart Prometheus:

```sh
docker compose restart prometheus
```

Importing a time range that is already stored creates overlapping blocks,
which Prometheus merges. Where two samples of a series share a timestamp, only
one is kept, so you cannot tell which value wins. To replace data you already
imported, reset the stack and import again.

## Resetting

Stop the stack and keep all data:

```sh
docker compose down
```

Delete all stored time series **and** Grafana state (users, settings):

```sh
docker compose down -v
```

Files in `./import/` are left untouched either way.

## Testing

`scripts/smoke-test.sh` checks the whole path end to end:

```sh
scripts/smoke-test.sh
```

It starts a separate copy of the stack (compose project `prom-smoke`, ports
19090 and 13000) with its own temporary import folder, ignoring your `.env`.
It imports the sample file plus two invalid files (no `# EOF`, millisecond
timestamps), then checks:

- the importer exits non-zero and routes each file to `processed/` or `failed/`;
- a sample value is queryable in Prometheus within 120 seconds;
- Grafana's Prometheus datasource reports healthy;
- a second import run finds nothing to do.

It removes its containers, volumes and temporary folder on exit, and can run
while your own stack is up without touching its data or `./import/`. It takes
about a minute and exits non-zero if any check fails. If ports 19090 or 13000
are taken, set `SMOKE_PROMETHEUS_PORT` / `SMOKE_GRAFANA_PORT`.
