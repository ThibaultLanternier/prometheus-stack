# Design

## Context

The stack from `add-prometheus-grafana-stack` already runs:
- Prometheus, with on-demand OpenMetrics backfill through a profiled `importer` service;
- Grafana, provisioned from `grafana/provisioning/` and with dashboards in `grafana/dashboards/`;
- a host-side smoke test (`scripts/smoke-test.sh`) that runs an isolated `prom-smoke` project.

This change adds Loki for storage and Grafana Alloy for ingestion, configured with no custom code. See proposal.md for why, and the `transaction-logs` and `monitoring-stack` deltas for the required behavior.

Facts checked while planning:
- **Loki:** the latest stable is 3.7.10 (4.0 is still a release candidate). `grafana/loki:3.7.10` has **no shell** and no health subcommand. It supports `-config.expand-env=true` and `-verify-config`.
- **Alloy:** the latest is v1.22.0. `grafana/alloy:v1.22.0` has `sh` but **neither `wget` nor `curl`**, and runs as root. Its default command is `run /etc/alloy/config.alloy --storage.path=/var/lib/alloy/data`, and its HTTP server (UI, `/metrics`, `/-/ready`) listens on `127.0.0.1:12345` unless overridden.
- **Loki defaults that block historical ingestion:**
  - `reject_old_samples` is true with a 1-week max age;
  - `max_query_length` is 721h;
  - `creation_grace_period` is 10m;
  - retention needs the compactor with `retention_enabled`.
- **Out-of-order writes in Loki:** they are accepted only within `max_chunk_age / 2` (1h by default) of the newest entry of a stream still held by the ingester.
- **Duplicates in Loki:** an entry whose stream, timestamp and line all match an existing one is dropped, so re-sends are idempotent.
- **Alloy's file source:** `loki.source.file` adds a `filename` label to every entry. It must be removed to keep exactly three labels.

## Goals / Non-Goals

**Goals:**
- No custom code on the ingestion path. Alloy's pipeline config is the whole implementation.
- A line is either stored with the timestamp from its `date`, or dropped and counted. It is never stored with a wrong timestamp.
- Re-reading files (restart, rename, full re-ingestion) never duplicates transactions.

**Non-Goals:**
- Per-file atomicity, or moving files to `processed/` and `failed/` (see proposal Impact).
- Detecting duplicate `id`s with different content: they are stored as two transactions.
- Structured metadata, Loki rules or alerting, multi-tenancy, object storage.
- A Grafana panel computing totals.

## Decisions

### D1. Layout
```
loki/loki.yml                          # single-binary config, env-expanded
alloy/config.alloy                     # file -> validate -> label -> Loki pipeline
examples/transactions.jsonl            # made-up sample (Jan-Mar 2025)
grafana/dashboards/transactions.json   # "Transactions" dashboard
grafana/provisioning/datasources/prometheus.yml   # + Loki datasource entry
prometheus/prometheus.yml              # + loki and alloy scrape jobs
import-transactions/                   # watched folder (.gitkeep), *.jsonl git-ignored
```

### D2. Loki: single binary, filesystem storage, limits opened up for history
`grafana/loki:3.7.10` runs with `-config.file=/etc/loki/loki.yml -config.expand-env=true` and stores everything in the `loki-data` volume at `/loki`.

Base settings:
- `auth_enabled: false`;
- `common` uses `replication_factor: 1`, an in-memory ring and filesystem storage;
- one `schema_config` period with `tsdb` and `v13`, starting at `1970-01-01`.

Limits:

| Setting | Value | Why |
| --- | --- | --- |
| `reject_old_samples` | `false` | accept any age |
| `retention_period` | `${LOKI_RETENTION:-10y}` | long-term, configurable |
| `max_query_length`, `max_query_lookback` | `0` (unlimited) | multi-year browsing |
| `max_entries_limit_per_query` | `50000` | above the dashboard's 5,000 lines |
| `creation_grace_period` | `25h` | entries more than 1 day ahead are rejected by Loki (see D5) |

The compactor has `retention_enabled: true` and `delete_request_store: filesystem`.

`ingester.max_chunk_age` is raised to `87600h`, which widens the out-of-order window to about 5 years. Chunks still flush on `chunk_idle_period` and on size. This is the riskiest setting, and the Loki spike (task 2.3) verifies it first.

*Alternatives:*
- Adding a time-based label: it breaks the three-label contract.
- Requiring chronological ingestion: it forbids backfilling older history later.

**Spike results (task 2.3, Loki 3.7.10)**

All checks pass. They needed two settings that were not in the original plan:

| Check | Result |
| --- | --- |
| Entries dated 2 years ago | accepted |
| 2023 entries pushed after 2025 entries of the same stream | accepted |
| 2022 entry pushed after `restart loki`, into a stream whose newest entry is 2025 | accepted |
| Re-pushing 7 identical entries after `POST /flush`, and after a restart | count unchanged (7) |
| Same timestamp, different line | both kept |
| Push with a valid entry and one 3 days ahead | HTTP 400 "timestamp too new" for the future entry. The valid one is stored, and `loki_discarded_samples_total{reason="too_far_in_future"}` is 1 |
| 4-year `query_range` | **initially timed out after about 60 s**. It takes 0.4 s with `split_queries_by_interval: 0` |
| Labels of a pushed stream | **Loki added `service_name`**. It is exactly `job`, `account`, `type` with `discover_service_name: []` |

Both settings were added to `limits_config`, along with `discover_log_levels: false`, which stops Loki from adding a detected level to every line.

The smoke test (task 5.1) later found that the instant metric query `count_over_time(...[3650d])` returned nothing, and 1000 days took 21 s. Loki splits instant metric queries and label lookups by their own intervals (`split_instant_metric_queries_by_interval: 1h`, `split_metadata_queries_by_interval`). Both are set to `0` too. A 10-year count now takes 0.6 s, and 10-year label values take 0.09 s.

### D3. No container healthchecks for Loki and Alloy
Neither image provides an HTTP client: Loki has no shell, and Alloy has `sh` but neither `wget` nor `curl`. So:
- `loki` and `alloy` have no compose `healthcheck`;
- Grafana and Alloy use `depends_on: loki: condition: service_started`. Alloy's `loki.write` retries until Loki is ready, and Grafana tolerates a datasource that becomes ready later;
- readiness is checked over HTTP by the smoke test (`/ready` for Loki, `/-/ready` for Alloy) and is documented in the README.

### D4. Alloy service
`grafana/alloy:v1.22.0` runs with:
```
run /etc/alloy/config.alloy --storage.path=/var/lib/alloy/data --server.http.listen-addr=0.0.0.0:12345
```

Mounts:
- `./alloy/config.alloy` read-only;
- `${IMPORT_TRANSACTIONS_DIR:-./import-transactions}` at `/import`, **read-only**, because Alloy never modifies files;
- the `alloy-data` volume at `/var/lib/alloy/data`, which holds the read positions.

Port `127.0.0.1:${ALLOY_PORT:-12345}:12345`. The listen address is opened inside the container so Prometheus can scrape it.

**Re-ingestion command** (spec "Full re-ingestion"): drop the positions by recreating the volume.
```sh
docker compose rm -sf alloy && docker volume rm prometheus-stack_alloy-data && docker compose up -d alloy
```
Every file is then read from the start, and Loki's duplicate dropping keeps each transaction once.

### D5. Alloy pipeline (`alloy/config.alloy`)
```
local.file_match "transactions"  path /import/*.jsonl, sync_period 10s
        |
loki.source.file "transactions"  tail_from_end = false (new files read from the start)
        |
loki.process "transactions"
   1. stage.json       extract id, date, account, type, amount, description;
                       a malformed line yields no fields (drop_malformed off,
                       since it would drop without counting)
   2. stage.labels     copy every extracted field into a TEMPORARY label (tx_*)
   3. stage.match x N  selectors with negative regexes, action "drop", one reason each:
                         {tx_id!~".+"} / {tx_amount!~".+"} / ...      -> malformed_or_missing_field
                         {tx_date!~"<YYYY-MM-DD | RFC 3339 w/ offset>"} -> invalid_date
                         {tx_account!~"^[a-z][a-z0-9_-]{0,63}$"}      -> invalid_account
                         {tx_account=~".*[0-9]{6,}.*"}                 -> invalid_account
                         {tx_type!~"^[A-Z][A-Z0-9_]{0,31}$"}           -> invalid_type
   4. stage.timestamp  source date, format 2006-01-02, fallback RFC 3339 (+ fractional);
                       safe because step 3 already removed every unparseable date
   5. stage.static_labels  job = "transactions"
   6. stage.labels     account, type (from the extracted values)
   7. stage.label_drop     all tx_* labels and filename
        |
loki.write  -> http://loki:3100/loki/api/v1/push
            retries with backoff for at least 5 minutes (max_backoff_period / max_backoff_retries)
```

The line is never rewritten. It reaches Loki byte for byte as it is in the file, which keeps amounts exact and makes duplicate dropping work.

**Why temporary labels:** `stage.match` selectors support negative regex matching (`!~`) on labels. A missing field gives an absent label, which matches `!~".+"`. This expresses "drop unless valid" with stock stages only.

`stage.drop` would need a positive "is invalid" regex for every rule, and RE2 has no negative lookahead. The temporary labels never leave Alloy, because step 7 removes them.

**Future dates:** Alloy has no "newer than" drop. Loki enforces this instead: `creation_grace_period` is 25h, and Loki discards such entries with reason `too_far_in_future`, counted in `loki_discarded_samples_total`. A rejected entry does not block the other entries of the same push, and Task 2.3 checks this.

**Calendar dates:** the `invalid_date` regex accepts only real dates from 1900 to 2099, leap years included. `stage.timestamp` cannot drop a line it fails to parse: on failure it reuses the previous timestamp, or the time the line was read. So a format-only regex would let `2025-02-30` be stored at a wrong time.

**Spike results (task 3.2):**
- Fixture: 23 lines, 6 valid and 17 invalid, one per drop case.
- **Stored:** exactly the 6 valid lines, at the expected UTC instants (date-only, `+01:00` offset, fractional `Z`, 2024-02-29), with labels `job`, `account` and `type` only.
- **Dropped:** malformed_or_missing_field 9, invalid_date 4, invalid_account 3, invalid_type 1.
- **Two findings, both fixed:**
  - `drop_malformed = true` dropped lines without counting them;
  - selectors reject backtick strings, so regex dots are written `[.]`.

*Alternatives:*
- `stage.regex` with named groups plus `stage.drop`: drops can't be expressed when a group is absent.
- A JSON schema check: Alloy has no such stage.

### D6. Observability of drops
`prometheus/prometheus.yml` gains two scrape jobs: `loki` (`loki:3100`) and `alloy` (`alloy:12345`).

The Transactions dashboard has a **Dropped lines (last 7 days)** bar gauge on the Prometheus datasource, with a panel-level relative time `7d` so it ignores the dashboard's transaction-date range. It has one instant query per source (`M` is `loki_process_dropped_lines_total{component_id="loki.process.transactions"}`, then `loki_discarded_samples_total{tenant="fake"}`):
```promql
clamp_min(sum by (reason) (M - M offset $__range), 0) or sum by (reason) (M)
```

*Why not `increase()`:* Alloy and Loki create a counter series for a reason only at its first drop. Prometheus's first sample of that series already holds the count, so `increase()` reports 0 for exactly the drops we want to show. The query takes the difference over the window when the series already existed 7 days ago, and the whole value when it appeared inside the window. If Alloy restarts within the window, the counter resets and is undercounted, never overcounted. That limitation is documented. Verified in task 4.4: all five reasons are reported with their exact counts.

### D7. Grafana: Loki datasource and Transactions dashboard
The datasource file gains a Loki entry: `uid: loki`, `url: http://loki:3100`, `jsonData.maxLines: 5000`. It is not the default.

The `transactions.json` dashboard has:
- **Variables:**
  - `account`: query `label_values({job="transactions"}, account)`, multi-select, include All, with `allValue` `.+`;
  - `type`: the same, for the `type` label;
  - `search`: a textbox, empty by default.
- **Logs panel** with the query:
  ```logql
  {job="transactions", account=~"$account", type=~"$type"} |~ "(?i)${search:regex}"
    | json | line_format "{{.date}}  {{.account}}  {{.type}}  {{.amount}}  {{.description}}"
  ```
- **Dropped-lines panel** (D6).
- A default time range covering the sample file, and `timezone: utc`.

### D8. Sample file
`examples/transactions.jsonl` holds about 40 made-up transactions from January to March 2025:
- accounts `courant` and `livret_joint`; types `CARD`, `TRANSFER`, `DIRECT_DEBIT`;
- `SUPERMARCHE` descriptions for the search scenario;
- one date-time with an offset, an optional `currency` field, and two purchases identical except for `id`.

It contains no real account data.

### D9. Configuration
`.env.example` gains:
- `LOKI_PORT=3100`;
- `ALLOY_PORT=12345`;
- `LOKI_RETENTION=10y`;
- `IMPORT_TRANSACTIONS_DIR=./import-transactions`.

`.gitignore` gains `import-transactions/*.jsonl`.

### D10. Tests
There is no custom code, so there are no unit tests. Each rule in the Alloy pipeline is checked by behaviour, first in the pipeline spike (task 3.2) and permanently in the smoke test.

**Smoke test** (same `prom-smoke` project):
- **Setup:**
  - alternate ports: Loki `13100`, Alloy `22345`;
  - temporary transactions folder;
  - fixtures:
    - the sample;
    - one file mixing valid lines with one line per drop reason (malformed JSON, missing field, invalid date, account number, bad type, date 3 days ahead);
    - an overlapping copy of part of the sample;
    - an older-year file added after newer data.
- **Assertions:**
  - the sample count is reached within 60 s;
  - only the valid lines of the mixed file are stored;
  - each drop reason is counted (via Prometheus);
  - the count is unchanged after the overlapping file;
  - the older-year entries are queryable;
  - the `supermarche` search count is as expected;
  - nothing is re-read after `restart alloy`;
  - Grafana's Loki datasource is healthy.

**Lint:** `alloy fmt` (from the pinned image) on `config.alloy`, Loki `-verify-config`, plus the existing shellcheck, compose and promtool checks.

## Risks / Trade-offs

- [The wide `max_chunk_age` does not allow "older after newer" ingestion, or breaks after a flush or restart] → Task 2.3 is a spike that tests exactly this before Alloy is wired in. If it fails, stop and revisit D2 or the spec with the user.
- [A pipeline rule silently lets a bad line through, or drops a good one, since config has no unit tests] → Task 3.2 is a spike that tests each rule with one fixture line per case. The smoke test keeps those fixtures as a permanent regression check.
- [Loki down for longer than Alloy's retry budget loses lines already read] → The retry budget is set to at least 5 minutes, and the README documents the full re-ingestion command, which is safe thanks to duplicate dropping.
- [Partial files: half a file can be stored while some lines are dropped] → Accepted trade-off for zero custom code. The dropped-lines panel makes it visible.
- [Byte-identical requirement for duplicate detection] → Documented in the README file-format section, with `id` required so the generator has a stable key.
- [Alloy reads files while they are still being written] → A partial last line would be held until a newline arrives, which `loki.source.file` handles. The README recommends writing the file elsewhere and then moving it into the folder.
- [Long-running ingestion service] → Alloy's footprint is small, and the read-only mount limits what it can touch.
- [Pinned Loki 3.7 / Alloy 1.22] → Upgrades are separate changes.

## Migration Plan

For an existing stack:
1. `git pull`, then `docker compose up -d`. This creates `loki-data` and `alloy-data` and starts Loki and Alloy. Prometheus and Grafana data are untouched.
2. Run `docker compose restart prometheus grafana`, because both read the changed config and provisioning only at startup. The README says so.

To roll back, revert the commit, run `docker compose up -d --remove-orphans`, then `docker volume rm prometheus-stack_loki-data prometheus-stack_alloy-data`.
