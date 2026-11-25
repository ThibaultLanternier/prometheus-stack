# prometheus-stack

A local Prometheus + Loki + Grafana stack for exploring your own historical data:

- **Time series** (e.g. daily account balances): you write them as OpenMetrics
  text files and backfill them into Prometheus with a single command.
- **Bank transactions**: you write them as JSON Lines files and drop them in a
  folder. Grafana Alloy ships them to Loki, where you browse them by date and
  account and search their descriptions.

## Requirements

- Docker Engine with Docker Compose v2 or later. Nothing else is needed on the host.

## Quick start

```sh
cp .env.example .env          # then set GF_SECURITY_ADMIN_PASSWORD
docker compose up -d
```

- Grafana: <http://localhost:3000> (log in with the credentials from `.env`)
- Prometheus: <http://localhost:9090>
- Loki API: <http://localhost:3100> (ready when `curl localhost:3100/ready` prints `ready`)
- Alloy UI: <http://localhost:12345> (ready when `curl localhost:12345/-/ready` succeeds)

All ports are bound to `127.0.0.1` only, so other machines on your network
cannot reach them. Loki and Alloy have no Docker healthcheck (their images ship
no HTTP client), so `docker compose ps` shows no health status for them: use the
URLs above.

### Upgrading an existing stack

After pulling a new version, run `docker compose up -d`, then
`docker compose restart prometheus grafana`. Prometheus and Grafana read their
configuration and provisioning only at startup, and `up -d` does not restart
them when only those files changed.

### Configuration (`.env`)

| Variable | Default | Purpose |
| --- | --- | --- |
| `PROMETHEUS_PORT` | `9090` | Host port for Prometheus |
| `PROMETHEUS_RETENTION` | `10y` | How long samples are kept. Keep it long, or backfilled history gets deleted |
| `PROMETHEUS_LOOKBACK_DELTA` | `5m` | PromQL lookback window, see [Sparse data](#sparse-data-and-lookback) |
| `GRAFANA_PORT` | `3000` | Host port for Grafana |
| `GF_SECURITY_ADMIN_USER` | `admin` | Grafana admin user |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Grafana admin password |
| `IMPORT_DIR` | `./import` | Folder the metrics importer reads from |
| `LOKI_PORT` | `3100` | Host port for Loki |
| `LOKI_RETENTION` | `10y` | How long transactions are kept |
| `ALLOY_PORT` | `12345` | Host port for the Alloy UI |
| `IMPORT_TRANSACTIONS_DIR` | `./import-transactions` | Folder Alloy watches for transaction files |

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

## Transactions: file format

Transactions are [JSON Lines](https://jsonlines.org/) files with the `.jsonl`
extension: one JSON object per line, one transaction per object.

```text
{"id":"2025-0042","date":"2025-01-03","account":"courant","type":"CARD","amount":-42.50,"description":"CB SUPERMARCHE DU QUARTIER"}
{"id":"2025-0043","date":"2025-01-03T14:22:00+01:00","account":"courant","type":"CARD","amount":-4.50,"description":"CB CAFE DE LA GARE","currency":"EUR"}
{"id":"2025-0044","date":"2025-01-04","account":"livret_joint","type":"TRANSFER","amount":200.00,"description":"VIREMENT DEPUIS COMPTE COURANT"}
```

| Field | Required | Rules |
| --- | --- | --- |
| `id` | yes | Unique per transaction (see [Duplicates](#duplicates)) |
| `date` | yes | `YYYY-MM-DD` (stored at 00:00 UTC), or a date-time **with** an offset: `2025-01-03T14:22:00+01:00`, `2025-01-03T13:22:00Z`. Must be a real date between 1900 and 2099, at most one day in the future |
| `account` | yes | Short readable name: lowercase letter first, then lowercase letters, digits, `_` or `-` (max 64). Never an account number or IBAN: six or more digits in a row are rejected |
| `type` | yes | Uppercase letters, digits and `_`, starting with a letter (max 32), e.g. `CARD`, `TRANSFER`, `DIRECT_DEBIT` |
| `amount` | yes | A number, negative for debits. It is stored exactly as written (`-42.50` stays `-42.50`) |
| `description` | yes | Free text: what the search box searches |
| anything else | no | Kept and visible in Grafana (e.g. `currency`) |

`account` and `type` become Loki labels, used to filter quickly. Everything
else stays in the stored line, which is your original line, unchanged.

**Privacy:** labels are indexed and shown everywhere in Grafana, which is why
`account` must be a nickname like `courant` or `livret_joint`, never a real
account number. Keep real numbers out of the files altogether if you can.

### Duplicates

Loki stores a transaction once even if it is read several times, as long as
its line is **byte-for-byte identical** each time. Re-reading a file, copying it
under another name, or adding an overlapping export never duplicates anything,
**if your export script writes the same transaction identically every time**
(same field order, same formatting).

Two real transactions with the same date, account, type, amount and
description, such as two identical coffees, must have different `id`s, or they
would be stored as one. If your bank gives no reference number, generate one,
for example `<date>-<account>-<position within that day>`.

See [`examples/transactions.jsonl`](examples/transactions.jsonl) for 40 made-up
transactions (January to March 2025).

## Ingesting transactions

With the stack running, copy files into `./import-transactions/`:

```sh
cp examples/transactions.jsonl import-transactions/
```

There is no command to run. Alloy watches the folder and the transactions are
searchable within about a minute. Open the **Transactions** dashboard in
Grafana: filter by account and type, type a word in **Search**
(case-insensitive), and pick the dates with the time picker.

- Write a file elsewhere and then move it into the folder. Alloy reads lines as
  soon as they appear.
- Files stay in the folder. Alloy remembers how far it has read each file, so a
  restart does not read them again. Lines appended to a file later are
  ingested too.
- Deleting a file from the folder does not delete its transactions.

### Rejected lines

A line that breaks a rule is **not stored, and the rest of the file still
is**. Each rejected line is counted in the **Dropped lines (last 7 days)**
panel of the Transactions dashboard, by reason:

| Reason | Meaning |
| --- | --- |
| `malformed_or_missing_field` | Not a JSON object, or a required field is missing or empty |
| `invalid_date` | Not `YYYY-MM-DD` or a date-time with offset, or not a real date |
| `invalid_account` | Not a short readable name, or looks like an account number |
| `invalid_type` | Not an uppercase type name |
| `too_far_in_future` (Loki) | Dated more than one day ahead |

That panel ignores the dashboard's time range: it always shows what was dropped
in the last 7 days. It can undercount if Alloy restarted during that period. To
find the exact lines, check Alloy's log (`docker compose logs alloy`) or compare
your file with what the dashboard lists.

To fix rejected lines, correct them and add them in a **new** file. Don't edit
a file that was already read: Alloy tracks how far it has read, so changes
before that point are not picked up.

### Re-ingesting everything

If Loki was down for more than about 14 minutes while files were being added,
transactions read during that time may be lost. Re-read every file from the
start:

```sh
docker compose rm -sf alloy && docker volume rm prometheus-stack_alloy-data && docker compose up -d alloy
```

This is always safe: transactions already stored are not duplicated (see
[Duplicates](#duplicates)).

## Resetting

Stop the stack and keep all data:

```sh
docker compose down
```

Delete all stored time series, transactions, Alloy's record of read files
**and** Grafana state (users, settings):

```sh
docker compose down -v
```

Files in `./import/` and `./import-transactions/` are left untouched either
way. After `down -v`, Alloy reads every file in `./import-transactions/` again
on the next start.

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
