# Tasks

## 1. Scaffolding

- [x] 1.1 Create `loki/`; verify `ls -RA` shows it
- [x] 1.2 Extend `.env.example` with `LOKI_PORT` and `LOKI_RETENTION` (D5)

## 2. Loki service

- [x] 2.1 Write `loki/loki.yml` per D2 and verify `docker run --rm -v $PWD/loki:/etc/loki:ro grafana/loki:3.7.10 -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config` succeeds
- [x] 2.2 Add the `loki` service to `docker-compose.yml` (pinned tag, expand-env flag, `loki-data` volume, `127.0.0.1:${LOKI_PORT:-3100}` port, no healthcheck per D3). Verify:
  - `docker compose config -q` passes;
  - `curl -s localhost:3100/ready` returns `ready` within 60 s of `docker compose up -d`;
  - `ss -ltn` shows `127.0.0.1:3100` only;
  - `/config` reports the `LOKI_RETENTION` value from `.env` and `10y` without it.
- [x] 2.3 Spike: use `curl` against `/loki/api/v1/push` and `/loki/api/v1/query_range` to verify that:
  - entries dated 2 years ago are accepted;
  - 2023 entries pushed after 2025 entries of the same stream are accepted, including after `docker compose restart loki`;
  - re-pushing identical entries, including after `POST /flush`, leaves query counts unchanged;
  - an entry 3 days in the future is discarded and counted in `loki_discarded_samples_total{reason="too_far_in_future"}`, while the other entries of the same push are stored;
  - a 3-year `query_range` succeeds.

  Record the results in design.md. If any check fails, stop and revisit D2 or the spec with the user.
- [x] 2.4 Verify persistence: after pushing an entry, `docker compose down && docker compose up -d` keeps it queryable, and `docker compose down -v` removes it

## 3. Grafana

- [x] 3.1 Add the Loki datasource to `grafana/provisioning/datasources/prometheus.yml` (D4: `uid: loki`, `maxLines: 5000`, not the default); verify after `docker compose restart grafana` that `curl -su admin:<pw> localhost:3000/api/datasources/uid/loki/health` reports OK and that Prometheus is still the default

## 4. Remove the descoped ingestion work

Already implemented on this branch, now out of scope (see proposal Impact).

- [x] 4.1 Remove the Alloy service and its `alloy-data` volume from `docker-compose.yml`, plus `alloy/`, `import-transactions/`, the `import-transactions/*.jsonl` line in `.gitignore`, and `ALLOY_PORT` and `IMPORT_TRANSACTIONS_DIR` in `.env.example`; verify `docker compose config -q` passes and `grep -rniE "alloy|import-transactions" --exclude-dir=openspec --exclude-dir=.git .` finds nothing
- [x] 4.2 Remove the `loki` and `alloy` scrape jobs from `prometheus/prometheus.yml`; verify `promtool check config` passes and, after `docker compose restart prometheus`, `/api/v1/targets` lists neither
- [x] 4.3 Remove `grafana/dashboards/transactions.json` and `examples/transactions.jsonl`; verify the dashboard is gone from `/api/search` after `docker compose restart grafana`
- [x] 4.4 Discard the uncommitted transaction smoke-test work (`scripts/smoke-test.sh` changes and `scripts/fixtures/`)

## 5. Documentation, smoke test and lint

- [ ] 5.1 Rewrite the README for Loki only:
  - intro: Loki is the store for transactions, ingestion comes later;
  - remove "Transactions: file format" and "Ingesting transactions";
  - "Quick start": the Loki URL and readiness check (`curl localhost:3100/ready`);
  - a short "Loki" section: the push API endpoint (`/loki/api/v1/push`), the historical limits (any age, any order, retention, future entries rejected) and browsing in Grafana Explore;
  - "Configuration" and "Resetting": Loki only, no Alloy or transactions folder;
  - restarting Grafana on upgrade.

  Verify that every documented command runs as written.
- [ ] 5.2 Extend `scripts/smoke-test.sh` per D6 (alternate Loki port, Loki `/ready` within 60 s, Grafana Loki datasource health) and update the README "Testing" section. Verify that it exits 0, leaves no `prom-smoke` containers or volumes behind, and that a main stack running at the same time keeps its data
- [ ] 5.3 Run Loki `-verify-config`, `shellcheck` on `scripts/*.sh`, `docker compose config -q` and `promtool check config`; fix all findings and verify that all pass and the smoke test still passes

## Workflow follow-up

- Open the PR against `develop` once all tasks are checked.
- Archive the change with `/opsx:archive`.
