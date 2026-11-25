# Tasks

## 1. Scaffolding

- [x] 1.1 Create `import-transactions/` (with `.gitkeep`), `loki/` and `alloy/`; verify `ls -RA` shows every path
- [x] 1.2 Extend `.gitignore` with `import-transactions/*.jsonl`, and `.env.example` with `LOKI_PORT`, `ALLOY_PORT`, `LOKI_RETENTION` and `IMPORT_TRANSACTIONS_DIR` (D9); verify `git check-ignore import-transactions/x.jsonl` lists the path

## 2. Loki service

- [x] 2.1 Write `loki/loki.yml` per D2 and verify `docker run --rm -v $PWD/loki:/etc/loki:ro grafana/loki:3.7.10 -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config` succeeds
- [x] 2.2 Add the `loki` service to `docker-compose.yml` (pinned tag, expand-env flag, `loki-data` volume, `127.0.0.1:${LOKI_PORT:-3100}` port, no healthcheck per D3). Verify:
  - `docker compose config -q` passes;
  - `curl -s localhost:3100/ready` returns `ready` within 60 s of `docker compose up -d`;
  - `ss -ltn` shows `127.0.0.1:3100` only;
  - `/config` reports the `LOKI_RETENTION` value from `.env` and `10y` without it.
- [x] 2.3 Spike, before wiring Alloy: use `curl` against `/loki/api/v1/push` and `/loki/api/v1/query_range` to verify that:
  - entries dated 2 years ago are accepted;
  - 2023 entries pushed after 2025 entries of the same stream are accepted, including after `docker compose restart loki`;
  - re-pushing identical entries, including after `POST /flush`, leaves query counts unchanged;
  - an entry 3 days in the future is discarded and counted in `loki_discarded_samples_total{reason="too_far_in_future"}`, while the other entries of the same push are stored;
  - a 3-year `query_range` succeeds.

  Record the results in design.md. If any check fails, stop and revisit D2 or the spec with the user.
- [x] 2.4 Verify persistence: after pushing an entry, `docker compose down && docker compose up -d` keeps it queryable, and `docker compose down -v` removes it

## 3. Alloy ingestion

- [ ] 3.1 Add the `alloy` service (D4: pinned tag, command with storage path and `0.0.0.0:12345` listen address, read-only config and import mounts, `alloy-data` volume, `127.0.0.1:${ALLOY_PORT:-12345}` port, `depends_on` loki started) with a minimal `alloy/config.alloy` (file match, file source, `json` stage, three labels, `filename` label dropped, timestamp, write). Verify:
  - `docker compose up -d` starts it and `curl -s localhost:12345/-/ready` succeeds;
  - a one-line valid file copied into `import-transactions/` is queryable in Loki within 60 s, at its `date`, with exactly the labels `job`, `account` and `type`.
- [ ] 3.2 Pipeline spike, then the validation stages (D5 steps 2, 3 and 7). Build a fixture file with:
  - valid lines: date-only, date-time with offset, and two lines identical except for `id`;
  - one line per drop reason: malformed JSON, each missing field, invalid date, naive date-time, account number, IBAN-like account, bad type.

  Verify:
  - exactly the valid lines are stored, at their expected UTC timestamps;
  - `loki_process_dropped_lines_total` on `localhost:12345/metrics` increases by the expected count per reason;
  - no `tx_*` or `filename` label reaches Loki (`/loki/api/v1/labels`).

  If a rule cannot be expressed with stock stages, stop and revisit D5 with the user.
- [ ] 3.3 Configure `loki.write` retries for at least 5 minutes, then verify the outage scenarios:
  - **short outage:** stop Loki, add a file, start Loki within 5 minutes, and the file's transactions become queryable;
  - **full re-ingestion:** the D4 re-ingestion command leaves every transaction count unchanged.
- [ ] 3.4 Verify the restart and duplicate scenarios:
  - after `docker compose down && docker compose up -d`, Alloy's positions survive, so no file is re-read (the `loki_source_file_read_lines_total` delta is 0) and counts are unchanged;
  - copying an ingested file under a new name leaves counts unchanged;
  - lines appended to an ingested file are ingested within 60 s.

## 4. Prometheus scrape, sample data and Grafana

- [ ] 4.1 Add the `loki` and `alloy` scrape jobs to `prometheus/prometheus.yml`; verify `promtool check config` passes and, after `docker compose restart prometheus`, `/api/v1/targets` shows both targets up
- [ ] 4.2 Write `examples/transactions.jsonl` per D8 (about 40 made-up transactions, Jan–Mar 2025); verify that within 60 s of copying it into `import-transactions/`, `sum(count_over_time({job="transactions"}[90d]))` at 2025-04-01 equals `wc -l examples/transactions.jsonl`
- [ ] 4.3 Add the Loki datasource to `grafana/provisioning/datasources/prometheus.yml` (D7: `uid: loki`, `maxLines: 5000`, not the default); verify after `docker compose restart grafana` that `curl -su admin:<pw> localhost:3000/api/datasources/uid/loki/health` reports OK and that Prometheus is still the default
- [ ] 4.4 Create `grafana/dashboards/transactions.json` per D6 and D7 (account, type and search variables; Logs panel with `line_format`; Dropped-lines panel with relative time `7d`; UTC; sample time range). Verify:
  - it appears in `/api/search`;
  - its logs query, run through `/api/ds/query` with `account=courant` and `search=supermarche`, returns only the matching sample lines;
  - its dropped-lines query returns the reasons produced in 3.2 while the dashboard range is January 2025.
- [ ] 4.5 Write the README sections:
  - **"Transactions: file format":** fields, date rules, label rules, `id` and byte-identical duplicate detection, privacy note, "write elsewhere then move" advice;
  - **"Ingesting transactions":** the watched folder, the dropped-lines panel, readiness URLs, the re-ingestion command, and restarting Prometheus and Grafana on upgrade;
  - updates to "Quick start", "Configuration" and "Resetting" for Loki and Alloy.

  Verify that every documented command runs as written and that the format example is fully ingested.

## 5. End-to-end smoke test and lint

- [ ] 5.1 Extend `scripts/smoke-test.sh` per D10:
  - **Setup:** alternate Loki and Alloy ports, a temporary transactions folder, and the fixtures.
  - **Assertions:**
    - the sample count is reached within 60 s;
    - the mixed file stores only its valid lines;
    - each drop reason is counted;
    - the count is unchanged after the overlapping copy;
    - older-year entries are queryable after newer ones;
    - the search count is as expected;
    - nothing is re-read after `restart alloy`;
    - Grafana's Loki datasource is healthy.

  Verify that it exits 0, leaves no `prom-smoke` containers or volumes behind, and that a main stack running at the same time keeps its data and both import folders unchanged.
- [ ] 5.2 Update the README "Testing" section for the transaction checks; verify the documented command runs as written
- [ ] 5.3 Run `alloy fmt` on `alloy/config.alloy` (from the pinned image), Loki `-verify-config`, `shellcheck` on `scripts/*.sh`, `docker compose config -q` and `promtool check config`; fix all findings and verify that all pass and the smoke test still passes

## Workflow follow-up

- Open the PR against `develop` once all tasks are checked.
- Archive the change with `/opsx:archive`.
