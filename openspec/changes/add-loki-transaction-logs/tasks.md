# Tasks

## 1. Scaffolding

- [ ] 1.1 Create `import-transactions/`, `import-transactions/processed/` and `import-transactions/failed/` with `.gitkeep` files, plus `loki/` and `scripts/tests/`; verify `ls -RA` shows every path
- [ ] 1.2 Extend `.gitignore` with `import-transactions/*.jsonl`, `import-transactions/processed/*.jsonl` and `import-transactions/failed/*.jsonl`, and `.env.example` with `LOKI_PORT`, `LOKI_RETENTION` and `IMPORT_TRANSACTIONS_DIR` (D8); verify `git check-ignore import-transactions/x.jsonl import-transactions/failed/x.jsonl` lists both

## 2. Loki service

- [ ] 2.1 Write `loki/loki.yml` per D2 and verify `docker run --rm -v $PWD/loki:/etc/loki:ro grafana/loki:3.7.10 -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config` succeeds
- [ ] 2.2 Add the `loki` service to `docker-compose.yml` (pinned tag, expand-env flag, `loki-data` volume, `127.0.0.1:${LOKI_PORT:-3100}` port, no healthcheck per D3). Verify:
  - `docker compose config -q` passes;
  - `curl -s localhost:3100/ready` returns `ready` within 60 s of `docker compose up -d`;
  - `ss -ltn` shows `127.0.0.1:3100` only;
  - `/config` reports the `LOKI_RETENTION` value from `.env` and `10y` without it.
- [ ] 2.3 Spike, before building the importer: use `curl` against `/loki/api/v1/push` and `/loki/api/v1/query_range` to verify that:
  - entries dated 2 years ago are accepted;
  - 2023 entries pushed after 2025 entries of the same stream are accepted, including after `docker compose restart loki`;
  - re-pushing identical entries, including after a flush (`POST /flush`), leaves query counts unchanged;
  - a 3-year `query_range` succeeds.

  Record the results in design.md. If any check fails, stop and revisit D2 or the spec with the user.
- [ ] 2.4 Verify persistence: after pushing an entry, `docker compose down && docker compose up -d` keeps it queryable, and `docker compose down -v` removes it

## 3. Importer

- [ ] 3.1 Implement parsing and validation in `scripts/import-transactions.py` (D5 step 1: required fields and types, date rules, label patterns, account-number rule, duplicate `id`, error collection with line numbers), with unit tests in `scripts/tests/test_import_transactions.py` for every rule; verify `docker run --rm -v $PWD/scripts:/scripts:ro -w /scripts python:3.15.2-alpine3.24 python -m unittest discover -s tests` passes
- [ ] 3.2 Implement stream building and batching (D5 steps 2–3: grouping by `job`/`account`/`type`, ns timestamps, sort, ≤ 1 MB batches, original line text) with unit tests for grouping, ordering, timestamp conversion and batch splitting; verify the unit tests pass
- [ ] 3.3 Implement the run loop:
  - wait up to 60 s for `/ready`;
  - push with retries on 429/5xx;
  - move each file to `processed/` or `failed/` with a timestamp prefix on name collision, and chown directories it creates;
  - print a summary, "Nothing to import" when there are no files, and exit 1 if any file failed.

  Add unit tests for the push retry decision and archive naming, using a stub HTTP server, and verify they pass.
- [ ] 3.4 Add the `transactions-importer` service (D4: profile `import`, `user: "0:0"`, mounts, `LOKI_URL`). Verify:
  - `docker compose up -d` does not start it;
  - with Loki stopped, `docker compose run --rm transactions-importer` exits non-zero after about 60 s with a clear message and moves pending files to `failed/`.

## 4. Sample data and Grafana

- [ ] 4.1 Write `examples/transactions.jsonl` per D7 (about 40 made-up transactions, Jan–Mar 2025). Verify:
  - the importer accepts it: `cp` to `import-transactions/`, run, file in `processed/`;
  - within 60 s, `sum(count_over_time({job="transactions"}[90d]))` at 2025-04-01 equals `wc -l examples/transactions.jsonl`.
- [ ] 4.2 Add the Loki datasource to `grafana/provisioning/datasources/prometheus.yml` (D6: `uid: loki`, `maxLines: 5000`, not the default); verify after `docker compose restart grafana` that `curl -su admin:<pw> localhost:3000/api/datasources/uid/loki/health` reports OK and that Prometheus is still the default
- [ ] 4.3 Create `grafana/dashboards/transactions.json` per D6 (account, type and search variables; Logs panel with `line_format`; UTC; sample time range). Verify:
  - it appears in `/api/search`;
  - its panel query, run through `/api/ds/query` with `account=courant` and `search=supermarche`, returns only the matching sample lines.
- [ ] 4.4 Write the README sections "Transactions: file format" (fields, date rules, label rules, `id` and byte-identical duplicate detection, privacy note) and "Importing transactions" (command, folders, failure and partial-import retry, Grafana restart on upgrade, `curl localhost:3100/ready`). Update "Quick start", "Configuration" and "Resetting" for Loki. Verify that every documented command runs as written and that the format example passes the importer.

## 5. End-to-end smoke test and lint

- [ ] 5.1 Extend `scripts/smoke-test.sh` per D9:
  - **Setup:** Loki port 13100, a temporary transactions folder, and the transaction fixtures.
  - **Assertions:**
    - exit codes and routing;
    - the count matches the sample within 60 s;
    - the count is unchanged after the overlapping import;
    - older-year entries are queryable after newer ones;
    - the text-search count is as expected;
    - Grafana's Loki datasource is healthy.

  Verify that it exits 0, leaves no `prom-smoke` containers or volumes behind, and that a main stack running at the same time keeps its data and both import folders unchanged.
- [ ] 5.2 Update the README "Testing" section for the transaction checks and the unit tests command; verify the commands run as written
- [ ] 5.3 Run `ruff check` (pinned `ghcr.io/astral-sh/ruff` image) on `scripts/`, `shellcheck` on `scripts/*.sh`, `docker compose config -q`, `promtool check config`, Loki `-verify-config` and the unit tests; fix all findings and verify that all pass and the smoke test still passes

## Workflow follow-up

- Open the PR against `develop` once all tasks are checked.
- Archive the change with `/opsx:archive`.
