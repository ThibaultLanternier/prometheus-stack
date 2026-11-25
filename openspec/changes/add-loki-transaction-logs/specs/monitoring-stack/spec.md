# Spec Delta

## MODIFIED Requirements

### Requirement: Single-command startup
The stack SHALL start Prometheus, Loki, Alloy and Grafana with one `docker compose up -d` command from the repository root. It SHALL need nothing on the host beyond Docker and Docker Compose.

#### Scenario: Fresh start
- **WHEN** the user runs `docker compose up -d` on a machine that has never run the stack
- **THEN** both Prometheus and Grafana containers reach a healthy state, and Loki and Alloy report ready on their readiness endpoints
- **AND** the Prometheus UI responds at `http://localhost:9090`, the Grafana UI at `http://localhost:3000`, the Loki API at `http://localhost:3100` and the Alloy UI at `http://localhost:12345`

#### Scenario: Importer not started by default
- **WHEN** the user runs `docker compose up -d`
- **THEN** the metrics importer does not run as part of startup

### Requirement: Localhost-only exposure
Prometheus, Loki, Alloy and Grafana ports SHALL bind to the loopback interface only, so other hosts on the network cannot reach them.

#### Scenario: Remote access refused
- **WHEN** another machine on the LAN connects to the host's port 9090, 3100, 12345 or 3000
- **THEN** the connection is refused

### Requirement: Data persistence across restarts
Prometheus time-series data, Loki log data, Alloy's record of the files it has read, and Grafana state SHALL survive container restarts and `docker compose down`. They are removed only when the user explicitly deletes the volumes.

#### Scenario: Restart keeps data
- **WHEN** data has been imported and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** the previously imported series are still queryable

#### Scenario: Restart keeps transactions
- **WHEN** transactions have been ingested and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** the previously ingested transactions are still queryable in Loki

#### Scenario: Explicit reset
- **WHEN** the user runs `docker compose down -v`
- **THEN** all stored time series, transactions, Alloy's read positions and Grafana state are removed

### Requirement: Grafana datasource provisioned
Grafana SHALL start with a default Prometheus datasource that points to the stack's Prometheus, and a Loki datasource that points to the stack's Loki, with no manual configuration.

#### Scenario: Datasource available on first login
- **WHEN** the user logs into Grafana for the first time
- **THEN** a Prometheus datasource exists, is the default, and its connection test succeeds

#### Scenario: Loki datasource available on first login
- **WHEN** the user logs into Grafana for the first time
- **THEN** a Loki datasource exists and its connection test succeeds

## ADDED Requirements

### Requirement: Stack components monitored by Prometheus
Prometheus SHALL scrape the metrics of Loki and Alloy in addition to its own, so ingestion problems can be graphed in Grafana.

#### Scenario: Scrape targets up
- **WHEN** the stack has been running for one minute
- **THEN** Prometheus reports its `loki` and `alloy` scrape targets as up
