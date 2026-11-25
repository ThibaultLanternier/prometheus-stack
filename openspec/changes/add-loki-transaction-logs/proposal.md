# Proposal

## Why

My bank transactions are individual records (a date, an account, a type, an amount and a description), not time series. The Prometheus side of the stack can only show balances over time. I want to browse transactions by date and account and search their descriptions in Grafana. Loki provides exactly that, label filtering plus full-text search, and fits the existing stack. Ingestion should rely on standard tooling, not custom code. Aggregates are not a goal.

## What Changes

- Add a Loki service to the Docker Compose stack:
  - single binary, filesystem storage, persisted in a named volume;
  - exposed on localhost only;
  - configured to accept old entries, in any order, and keep them long term, because its defaults reject entries older than a week and limit queries to 30 days.
- Add a Grafana Alloy service that watches `./import-transactions/` continuously. It parses each JSON Lines file (`.jsonl`) and ships the transactions to Loki. The whole pipeline is configuration, with no custom code. Dropping a file in the folder is enough to import it.
- Define and document the transaction file format: one JSON object per line with required `id`, `date`, `account`, `type`, `amount`, `description`, plus any optional extra fields. `account` and `type` become Loki labels. The whole object is stored as the log line.
- Drop invalid lines individually instead of storing them wrongly: a line with a missing field, an invalid date, an account number used as `account`, or a bad `type`. Each drop is counted with a reason.
- Make dropped lines visible: Prometheus scrapes Alloy's and Loki's metrics, and the Transactions dashboard shows the lines dropped in the last 7 days, by reason.
- Make re-importing safe: the same transaction imported twice is stored once, while distinct transactions with identical content on the same day stay separate thanks to `id`.
- Provision a Loki datasource in Grafana, plus a **Transactions** dashboard with account and type filters, a free-text search box, a statement-like view of each transaction and the dropped-lines panel.
- Ship a sample transactions file with made-up data and extend the smoke test to cover ingestion, dropped lines and text search.

## Capabilities

### New Capabilities
- `transaction-logs`: Storing bank transactions in Loki and exploring them. It covers the accepted file format, automatic ingestion from the watched folder, per-line rejection and its visibility, duplicate handling, long-term retention of historical entries, and browsing and searching in Grafana.

### Modified Capabilities
- `monitoring-stack`: The stack now includes Loki and Alloy:
  - startup, localhost-only exposure and persistence extend to both, with Alloy remembering what it has already read;
  - Grafana additionally provisions a Loki datasource;
  - Prometheus additionally scrapes Loki and Alloy.

## Impact

- New files: `loki/loki.yml`, `alloy/config.alloy`, `examples/transactions.jsonl`, `grafana/dashboards/transactions.json`, and `import-transactions/`.
- Modified files:
  - `docker-compose.yml` (adds the `loki` and `alloy` services and the `loki-data` and `alloy-data` volumes);
  - `prometheus/prometheus.yml` (Loki and Alloy scrape jobs);
  - the Grafana datasource provisioning;
  - `.env.example`, `.gitignore`, `scripts/smoke-test.sh` and `README.md`.
- New images, pinned: `grafana/loki` and `grafana/alloy`.
- New host ports: 3100 (Loki) and 12345 (Alloy UI), both bound to `127.0.0.1`.
- Files in `./import-transactions/` stay where they are after ingestion. There are no `processed/` or `failed/` folders, unlike the metrics import.
- An invalid line does not block the rest of its file. All-or-nothing import per file is deliberately given up for zero custom code.
- Converting bank exports (CSV and others) into the JSON Lines format is out of scope. The user produces the files.
- Aggregations over amounts (sums and totals by period) are out of scope.
