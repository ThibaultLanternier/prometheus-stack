# Proposal

## Why

My bank transactions are individual records (a date, an account, a type, an amount and a description), not time series. The Prometheus side of the stack can only show balances over time. Loki provides label filtering plus full-text search and fits the existing stack, so it is the right store for them.

This change only provides the store: a working Loki, connected to Grafana, that can accept historical entries. How transactions get into Loki (file format, ingestion tooling, validation and its monitoring) is handled separately, in a later change. So is a dedicated dashboard for browsing them.

## What Changes

- Add a Loki service to the Docker Compose stack:
  - single binary, filesystem storage, persisted in a named volume;
  - exposed on localhost only;
  - configured to accept old entries, in any order, and keep them long term, because its defaults reject entries older than a week and limit queries to 30 days.
- Provision a Loki datasource in Grafana, so Loki data can be queried in Explore with no manual setup.
- Extend the smoke test to check that Loki becomes ready and that Grafana's Loki datasource is healthy.
- Document Loki in the README: URL, readiness check, push API endpoint, configuration and reset.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `monitoring-stack`: The stack now includes Loki:
  - startup, localhost-only exposure and persistence extend to Loki;
  - Grafana additionally provisions a Loki datasource;
  - Loki accepts entries of any age and in any order, keeps them for a configurable retention period, and answers queries spanning that whole period.

## Impact

- New file: `loki/loki.yml`.
- Modified files:
  - `docker-compose.yml` (adds the `loki` service and the `loki-data` volume);
  - the Grafana datasource provisioning;
  - `.env.example`, `scripts/smoke-test.sh` and `README.md`.
- New image, pinned: `grafana/loki`.
- New host port: 3100 (Loki), bound to `127.0.0.1`.
- Out of scope, for a later change:
  - the transaction file format and the conversion of bank exports;
  - any ingestion pipeline (Alloy or other), line validation, duplicate handling and the monitoring of ingestion;
  - a Transactions dashboard;
  - aggregations over amounts.
