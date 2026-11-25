# Design

## Context

The stack from `add-prometheus-grafana-stack` already runs:
- Prometheus, with on-demand OpenMetrics backfill through a profiled `importer` service;
- Grafana, provisioned from `grafana/provisioning/` and with dashboards in `grafana/dashboards/`;
- a host-side smoke test (`scripts/smoke-test.sh`) that runs an isolated `prom-smoke` project.

This change adds Loki next to them and reuses the same patterns: drop folder, profiled importer, `processed/` and `failed/`, `.env` knobs, loopback ports, and the isolated smoke test. See proposal.md for why, and the `transaction-logs` and `monitoring-stack` deltas for the required behavior.

Facts checked while planning:
- **Image:** the latest stable Loki is 3.7.10 (4.0 is still a release candidate). The `grafana/loki:3.7.10` image has **no shell**, so `wget` and `sh` are unavailable, and the binary has no health subcommand. A compose `healthcheck` is therefore not possible.
- **Config:** Loki supports `-config.expand-env=true` with `${VAR:-default}` in its config file.
- **Defaults that block historical imports:**
  - `reject_old_samples` is true with a 1-week max age;
  - `max_query_length` is 721h;
  - `creation_grace_period` is 10m, so entries slightly in the future are rejected;
  - retention needs the compactor with `retention_enabled`.
- **Out-of-order writes:** they are allowed, but only within `max_chunk_age / 2` (1h by default) of the newest entry of a stream that the ingester still holds. Importing 2023 data after 2025 data for the same stream fails with "entry too far behind" unless this window is widened.
- **Duplicates:** Loki drops an entry whose timestamp and line both match an existing entry in the same stream, which makes re-pushes idempotent.

## Goals / Non-Goals

**Goals:**
- One `docker compose run --rm transactions-importer` imports every pending file. Each file is validated completely before anything is sent.
- Re-running an import, or importing overlapping exports, never duplicates transactions.
- The smoke test covers the Loki path without touching the user's data, just as it does for metrics.

**Non-Goals:**
- Structured metadata, Loki rules or alerting, multi-tenancy, object storage.
- Deleting individual transactions. That is done with Loki's delete API or `down -v` if ever needed.
- A Grafana panel computing totals.

## Decisions

### D1. Layout
```
loki/loki.yml                          # single-binary config, env-expanded
scripts/import-transactions.py         # importer (runs in python container)
scripts/tests/test_import_transactions.py   # unit tests for validation/batching
examples/transactions.jsonl            # made-up sample (Jan-Mar 2025)
grafana/dashboards/transactions.json   # "Transactions" dashboard
grafana/provisioning/datasources/prometheus.yml   # + Loki datasource entry
import-transactions/{processed,failed}/ # drop zone (.gitkeep), *.jsonl git-ignored
```

### D2. Loki: single binary, filesystem storage, limits opened up for history
`grafana/loki:3.7.10` runs with `-config.file=/etc/loki/loki.yml -config.expand-env=true` and stores everything in the `loki-data` volume at `/loki`.

Base settings:
- `auth_enabled: false`, so there is a single `fake` tenant;
- `common` uses `replication_factor: 1`, an in-memory ring and filesystem storage;
- one `schema_config` period with `tsdb` and `v13`, starting at `1970-01-01`, so every historical date falls in a defined period.

Limits:

| Setting | Value | Why |
| --- | --- | --- |
| `reject_old_samples` | `false` | accept any age |
| `retention_period` | `${LOKI_RETENTION:-10y}` | long-term storage, configurable |
| `max_query_length`, `max_query_lookback` | `0` (unlimited) | multi-year browsing |
| `max_entries_limit_per_query` | `50000` | above the dashboard's 5,000 lines |
| `creation_grace_period` | `25h` | matches the importer's "≤ 1 day ahead" rule |

The compactor has `retention_enabled: true` and `delete_request_store: filesystem`.

`ingester.max_chunk_age` is raised to `87600h`, which widens the out-of-order window to about 5 years. Chunks still flush on `chunk_idle_period` and on size, so this does not keep data in memory for long. This is the riskiest setting, and task 2.3 verifies it before anything is built on top.

*Alternatives:*
- Adding a time-based label such as `year`: it breaks the "exactly three labels" contract and only shifts the problem.
- Requiring imports in chronological order: it forbids backfilling older history later, which is a stated scenario.

### D3. No container healthcheck for Loki; readiness is polled over HTTP
The image has no shell, so `loki` has no compose `healthcheck`:
- Grafana uses `depends_on: loki: condition: service_started`. Grafana tolerates a datasource that becomes ready a few seconds later.
- The importer polls `http://loki:3100/ready` for up to 60 s before doing anything.
- The smoke test polls `localhost:$LOKI_PORT/ready`.

*Alternative:* a sidecar container that runs `wget` as a healthcheck. That is an extra service just to colour a status column.

### D4. Importer: stdlib Python in a pinned `python:3.15.2-alpine3.24` container
Shell plus awk cannot reliably parse JSON, check types and build the push payload, so the importer is Python. It uses only the standard library (`json`, `urllib`, `re`, `datetime`), so there is nothing to install.

The `transactions-importer` service:
- uses `profiles: [import]`, `user: "0:0"` and `entrypoint: ["python3", "/scripts/import-transactions.py"]`;
- mounts `${IMPORT_TRANSACTIONS_DIR:-./import-transactions}` at `/import` and `./scripts` read-only;
- sets `LOKI_URL=http://loki:3100`;
- has no access to any data volume, because it talks to Loki over the compose network only.

It runs as root for the same reason as the metrics importer: it must move files in a bind mount owned by the host user. Directories it has to create are `chown`ed to the owner of the import folder. *Alternative:* a `jq` + `curl` shell script, which handles per-field type checks and error reporting by line poorly.

### D5. Per-file flow: validate everything, then push
For each `*.jsonl` file, in name order:
1. **Parse and validate every line.** The format, label and date rules come from the spec. A repeated `id` within the file is an error. Errors are collected with line numbers, up to 20 per file, then the file is rejected. Nothing is sent for an invalid file.
2. **Build the streams.** Lines are grouped by `{job="transactions", account, type}` and sorted by timestamp within each stream. Each entry is `[<ns timestamp>, <original line text, trimmed>]`.
3. **Push** to `/loki/api/v1/push` in batches of at most about 1 MB:
   - 429 and 5xx responses are retried 3 times with backoff;
   - any other error stops the file;
   - a partly pushed file goes to `failed/` with "may be partly imported, safe to retry".
4. **Archive the file:** `processed/` on success, otherwise `failed/`. If the name is taken, the file gets a `YYYYMMDDTHHMMSS-` prefix, as in the metrics importer.

The run then prints a summary. It prints "Nothing to import" and exits 0 when there are no files, and exits 1 if any file failed.

**The line is the original text, not re-serialised.** This keeps amounts exactly as written (`-42.50`, not `-42.5`) and makes identical input produce identical log lines, which is what Loki's duplicate dropping relies on. The trade-off is that a re-export must write a transaction byte-for-byte identically to be recognised as a duplicate. The user's own generator is deterministic, so this holds, and it is documented.

Timestamps:
- `YYYY-MM-DD` is stored at 00:00 UTC.
- A date-time must carry an offset (`Z` or `±HH:MM`) and is converted to UTC.
- Naive date-times are rejected, so that a timezone is never guessed.

### D6. Grafana: Loki datasource and Transactions dashboard
The datasource file gains a Loki entry: `uid: loki`, `url: http://loki:3100`, `jsonData.maxLines: 5000`. It is not the default, because Prometheus stays the default.

The `transactions.json` dashboard has:
- **Variables:**
  - `account`: query `label_values({job="transactions"}, account)`, multi-select, include All, with `allValue` `.+`;
  - `type`: the same, for the `type` label;
  - `search`: a textbox, empty by default.
- **One Logs panel** with the query:
  ```logql
  {job="transactions", account=~"$account", type=~"$type"} |~ "(?i)${search:regex}"
    | json | line_format "{{.date}}  {{.account}}  {{.type}}  {{.amount}}  {{.description}}"
  ```
  `${search:regex}` escapes regex characters typed by the user. An empty search matches everything.
- A default time range covering the sample file, and `timezone: utc` so dates match the file.

### D7. Sample file
`examples/transactions.jsonl` holds about 40 made-up transactions from January to March 2025:
- accounts `courant` and `livret_joint`; types `CARD`, `TRANSFER`, `DIRECT_DEBIT`;
- descriptions that include `SUPERMARCHE` for the search scenario;
- one date-time with an offset, an optional `currency` field, and two purchases identical except for `id`.

It contains no real account data.

### D8. Configuration
`.env.example` gains:
- `LOKI_PORT=3100`, published as `127.0.0.1:${LOKI_PORT:-3100}:3100`;
- `LOKI_RETENTION=10y`;
- `IMPORT_TRANSACTIONS_DIR=./import-transactions`.

`.gitignore` gains the `import-transactions/**/*.jsonl` patterns.

### D9. Tests
- **Unit tests** (`scripts/tests/`, `unittest`, run with `docker run --rm python:3.15.2-alpine3.24 python -m unittest`). They cover:
  - each validation rule (missing field, wrong type, bad date, naive date-time, future date, account number, bad type, duplicate id, malformed JSON);
  - timestamp conversion;
  - stream grouping and sorting;
  - batch splitting.
- **Smoke test**, extended within the same `prom-smoke` project:
  - alternate Loki port `13100`, plus a temporary transactions import folder;
  - fixtures: the sample, a missing-field file, an account-number file, and an overlapping copy of part of the sample imported in a second run;
  - an older-year file imported after newer data.
  - Assertions:
    - exit codes and file routing;
    - the transaction count over the sample range equals the sample's line count within 60 s (via `sum(count_over_time(...))`, so the host needs only `curl`);
    - the count is unchanged after the overlapping import;
    - the older-year entries are queryable;
    - a `|~ "(?i)supermarche"` search returns the expected count;
    - Grafana's Loki datasource health is OK.
- **Lint:** `ruff check` (pinned `ghcr.io/astral-sh/ruff` image) on the Python files, in addition to the existing shellcheck, compose and promtool checks.

## Risks / Trade-offs

- [The wide `max_chunk_age` does not make "older after newer" imports work, or behaves differently after the ingester flushes] → Task 2.3 is a spike that tests exactly this before the importer is built. If it fails, the fallback is to document a `docker compose restart loki` before importing older history. The spec scenario would then need revisiting with the user before continuing.
- [Loki's duplicate dropping does not hold across flushed chunks] → The spike also tests a re-push after a flush. `processed/` already prevents re-importing the same file, and query-time deduplication covers overlapping chunks.
- [Byte-identical requirement for duplicate detection] → Documented in the README file-format section. The `id` is required, so the generator has a stable key to emit lines deterministically.
- [No Loki healthcheck, so `docker compose ps` shows no health for it] → Readiness is polled by the importer and the smoke test, and the README mentions `curl localhost:3100/ready`.
- [Root importer container] → It runs on demand only, with no data volume mounted, only the import folder and read-only scripts.
- [Loki 3.7 support window] → The tag is pinned. Upgrading to 4.x is a separate change once it is stable.
- [Memory use of a single-binary Loki] → Acceptable for a local stack with thousands of entries. No tuning is in scope.

## Migration Plan

For an existing stack:
1. `git pull`, then `docker compose up -d`. This creates `loki-data` and starts Loki. Prometheus and Grafana data are untouched.
2. Run `docker compose restart grafana`. Grafana reads datasource provisioning only at startup, and `up -d` does not recreate it when only the contents of mounted files change. The README update says so.

To roll back, revert the commit, run `docker compose up -d --remove-orphans`, then `docker volume rm prometheus-stack_loki-data`.
