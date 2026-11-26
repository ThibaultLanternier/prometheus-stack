# Design

## Context

The stack from `add-prometheus-grafana-stack` already runs:
- Prometheus, with on-demand OpenMetrics backfill through a profiled `importer` service;
- Grafana, provisioned from `grafana/provisioning/` and with dashboards in `grafana/dashboards/`;
- a host-side smoke test (`scripts/smoke-test.sh`) that runs an isolated `prom-smoke` project.

This change adds Loki as the store for bank transactions and connects it to Grafana. Getting transactions into Loki is a separate, later change. See proposal.md for why, and the `monitoring-stack` delta for the required behavior.

Facts checked while planning:
- **Loki:** the latest stable is 3.7.10 (4.0 is still a release candidate). `grafana/loki:3.7.10` has **no shell** and no health subcommand. It supports `-config.expand-env=true` and `-verify-config`.
- **Loki defaults that block historical ingestion:**
  - `reject_old_samples` is true with a 1-week max age;
  - `max_query_length` is 721h;
  - `creation_grace_period` is 10m;
  - retention needs the compactor with `retention_enabled`.
- **Out-of-order writes in Loki:** they are accepted only within `max_chunk_age / 2` (1h by default) of the newest entry of a stream still held by the ingester.
- **Duplicates in Loki:** an entry whose stream, timestamp and line all match an existing one is dropped, so re-sends are idempotent. A future ingestion change can rely on this.

## Goals / Non-Goals

**Goals:**
- A Loki that is ready to receive bank history: any age, any order, long-term retention, multi-year queries.
- Loki queryable from Grafana with no manual setup.

**Non-Goals:**
- Any ingestion tooling (Alloy, Promtail or custom code), file format, line validation, duplicate policy, or monitoring of ingestion. A later change owns them.
- A Transactions dashboard. Loki data is browsed in Grafana Explore until then.
- Prometheus scraping Loki's metrics.
- Structured metadata, Loki rules or alerting, multi-tenancy, object storage.

## Decisions

### D1. Layout
```
loki/loki.yml                                     # single-binary config, env-expanded
grafana/provisioning/datasources/prometheus.yml   # + Loki datasource entry
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
| `max_entries_limit_per_query` | `50000` | above the datasource's 5,000 lines (D4) |
| `creation_grace_period` | `25h` | entries more than 1 day ahead are rejected |

The compactor has `retention_enabled: true` and `delete_request_store: filesystem`.

`ingester.max_chunk_age` is raised to `87600h`, which widens the out-of-order window to about 5 years. Chunks still flush on `chunk_idle_period` and on size. This is the riskiest setting, and the Loki spike (task 2.3) verifies it first.

*Alternatives:*
- Adding a time-based label: it would force every future sender to add it.
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
| Labels of a pushed stream | **Loki added `service_name`**. With `discover_service_name: []` it keeps only the labels the sender set |

Both settings were added to `limits_config`, along with `discover_log_levels: false`, which stops Loki from adding a detected level to every line.

Later testing found that the instant metric query `count_over_time(...[3650d])` returned nothing, and 1000 days took 21 s. Loki splits instant metric queries and label lookups by their own intervals (`split_instant_metric_queries_by_interval: 1h`, `split_metadata_queries_by_interval`). Both are set to `0` too. A 10-year count now takes 0.6 s, and 10-year label values take 0.09 s.

### D3. No container healthcheck for Loki
The Loki image has no shell and no HTTP client. So:
- `loki` has no compose `healthcheck`;
- Grafana uses `depends_on: loki: condition: service_started`, and tolerates a datasource that becomes ready later;
- readiness is checked over HTTP (`/ready`) by the smoke test and is documented in the README.

### D4. Grafana: Loki datasource
The datasource file gains a Loki entry: `uid: loki`, `url: http://loki:3100`, `jsonData.maxLines: 5000`. It is not the default, so existing Prometheus dashboards are unaffected. Loki data is explored in Grafana Explore.

### D5. Configuration
`.env.example` gains:
- `LOKI_PORT=3100`;
- `LOKI_RETENTION=10y`.

### D6. Tests
There is no custom code, so there are no unit tests. Loki's historical behaviour is verified once by the spike (task 2.3) and persistence by task 2.4.

**Smoke test** (same `prom-smoke` project), health only:
- alternate Loki port `13100`;
- Loki's `/ready` returns `ready` within 60 s;
- Grafana's Loki datasource health check succeeds.

No data is pushed: the smoke test will cover ingestion when the ingestion change lands.

**Lint:** Loki `-verify-config`, plus the existing shellcheck, compose and promtool checks.

## Risks / Trade-offs

- [The wide `max_chunk_age` does not allow "older after newer" ingestion, or breaks after a flush or restart] → Task 2.3 is a spike that tests exactly this. It passed.
- [The smoke test does not check historical acceptance, so a later config change could break it unnoticed] → Accepted for now. The ingestion change will add data-level smoke checks.
- [Pinned Loki 3.7] → Upgrades are separate changes.

## Migration Plan

For an existing stack:
1. `git pull`, then `docker compose up -d`. This creates `loki-data` and starts Loki. Prometheus and Grafana data are untouched.
2. Run `docker compose restart grafana`, because it reads the changed provisioning only at startup. The README says so.

To roll back, revert the commit, run `docker compose up -d --remove-orphans`, then `docker volume rm prometheus-stack_loki-data`.
