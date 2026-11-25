# Proposal

## Why

My bank transactions are individual records (a date, an account, a type, an amount and a description), not time series. The Prometheus side of the stack can only show balances over time. I want to browse transactions by date and account and search their descriptions in Grafana. Loki provides exactly that, label filtering plus full-text search, and fits the existing stack. Aggregates are not a goal.

## What Changes

- Add a Loki service to the Docker Compose stack:
  - single binary, filesystem storage, persisted in a named volume;
  - exposed on localhost only;
  - configured to accept old entries and keep them long term, because its defaults reject entries older than a week and limit queries to 30 days.
- Provision a Loki datasource in Grafana, plus a **Transactions** dashboard with account and type filters, a free-text search box, and a statement-like view of each transaction.
- Add an on-demand transactions importer. It reads JSON Lines files (`.jsonl`) dropped in `./import-transactions/`, validates each file completely, and pushes the transactions to Loki. Like the metrics importer, it moves each file to `processed/` or `failed/`.
- Define and document the transaction file format: one JSON object per line with required `id`, `date`, `account`, `type`, `amount`, `description`, plus any optional extra fields. `account` and `type` become Loki labels. The whole object is stored as the log line.
- Make re-importing safe: the same transaction imported twice is stored once, while distinct transactions with identical content on the same day stay separate thanks to `id`.
- Ship a sample transactions file with made-up data and extend the smoke test to cover a transaction import and a text search.

## Capabilities

### New Capabilities
- `transaction-logs`: Storing bank transactions in Loki and exploring them. It covers the accepted file format, the import trigger, validation and handling of invalid files, duplicate handling, long-term retention of historical entries, and browsing and searching in Grafana.

### Modified Capabilities
- `monitoring-stack`: The stack now includes Loki. Startup, localhost-only exposure and persistence extend to Loki, and Grafana additionally provisions a Loki datasource.

## Impact

- New files: `loki/loki.yml`, `scripts/import-transactions.py`, `examples/transactions.jsonl`, `grafana/dashboards/transactions.json`, a Loki datasource entry, and `import-transactions/` with `processed/` and `failed/`.
- Modified files: `docker-compose.yml` (adds the `loki` and `transactions-importer` services and the `loki-data` volume), `.env.example`, `.gitignore`, the Grafana datasource provisioning, `scripts/smoke-test.sh` and `README.md`.
- New images, pinned: `grafana/loki` and `python` (Alpine variant) for the importer.
- New host port: 3100 (Loki), bound to `127.0.0.1`.
- Converting bank exports (CSV and others) into the JSON Lines format is out of scope. The user produces the files.
- Aggregations over amounts (sums and totals by period) are out of scope.
