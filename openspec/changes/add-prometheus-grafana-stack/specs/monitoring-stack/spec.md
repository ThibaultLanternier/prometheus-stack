# Spec Delta

## Purpose

Provides a local, single-command Prometheus and Grafana runtime that keeps historical time series and lets the user explore them in Grafana without any manual setup.

## ADDED Requirements

### Requirement: Single-command startup
The stack SHALL start Prometheus and Grafana with one `docker compose up -d` command from the repository root. It SHALL need nothing on the host beyond Docker and Docker Compose.

#### Scenario: Fresh start
- **WHEN** the user runs `docker compose up -d` on a machine that has never run the stack
- **THEN** both Prometheus and Grafana containers reach a healthy state
- **AND** the Prometheus UI responds at `http://localhost:9090` and the Grafana UI at `http://localhost:3000`

#### Scenario: Importer not started by default
- **WHEN** the user runs `docker compose up -d`
- **THEN** no import job runs as part of startup

### Requirement: Localhost-only exposure
Prometheus and Grafana ports SHALL bind to the loopback interface only, so other hosts on the network cannot reach them.

#### Scenario: Remote access refused
- **WHEN** another machine on the LAN connects to the host's port 9090 or 3000
- **THEN** the connection is refused

### Requirement: Data persistence across restarts
Prometheus time-series data and Grafana state SHALL survive container restarts and `docker compose down`. They are removed only when the user explicitly deletes the volumes.

#### Scenario: Restart keeps data
- **WHEN** data has been imported and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** the previously imported series are still queryable

#### Scenario: Explicit reset
- **WHEN** the user runs `docker compose down -v`
- **THEN** all stored time series and Grafana state are removed

### Requirement: Retention suitable for historical data
Prometheus SHALL default to a time-based retention of at least 10 years, so backfilled historical samples are not deleted. The retention SHALL be configurable through an environment variable in `.env`.

#### Scenario: Old samples kept
- **WHEN** samples timestamped two years in the past are imported with default settings
- **THEN** they remain queryable after Prometheus has run compaction

#### Scenario: Custom retention
- **WHEN** the user sets the retention variable in `.env` to `30d` and restarts the stack
- **THEN** Prometheus reports a storage retention of 30 days in its runtime info

### Requirement: Configurable query lookback
The PromQL lookback delta SHALL be configurable through an environment variable in `.env`, defaulting to Prometheus's standard 5 minutes. This lets series sampled less often than every 5 minutes render as continuous lines.

#### Scenario: Sparse series with increased lookback
- **WHEN** a series sampled every hour is imported and the lookback variable is set to `1h`
- **THEN** a Grafana time-series panel over that series shows a continuous line rather than isolated points

### Requirement: Grafana datasource provisioned
Grafana SHALL start with a default Prometheus datasource that points to the stack's Prometheus, with no manual configuration.

#### Scenario: Datasource available on first login
- **WHEN** the user logs into Grafana for the first time
- **THEN** a Prometheus datasource exists, is the default, and its connection test succeeds

### Requirement: Example dashboard provisioned
Grafana SHALL provision an example dashboard that displays the series from the bundled sample import file, so the user can confirm the end-to-end path.

#### Scenario: Sample data visible
- **WHEN** the sample file has been imported and the user opens the example dashboard with a time range covering the sample's timestamps
- **THEN** the panels display the sample series

### Requirement: Configurable Grafana admin credentials
Grafana admin credentials SHALL be read from `.env`. The repository SHALL contain no real secrets: only an `.env.example` with placeholder values, and `.env` SHALL be git-ignored.

#### Scenario: Custom password
- **WHEN** the user sets a Grafana admin password in `.env` before first start
- **THEN** Grafana accepts that password for the admin user
