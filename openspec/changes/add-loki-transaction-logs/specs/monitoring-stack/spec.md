# Spec Delta

## MODIFIED Requirements

### Requirement: Single-command startup
The stack SHALL start Prometheus, Loki and Grafana with one `docker compose up -d` command from the repository root. It SHALL need nothing on the host beyond Docker and Docker Compose.

#### Scenario: Fresh start
- **WHEN** the user runs `docker compose up -d` on a machine that has never run the stack
- **THEN** both Prometheus and Grafana containers reach a healthy state, and Loki reports ready on its readiness endpoint
- **AND** the Prometheus UI responds at `http://localhost:9090`, the Grafana UI at `http://localhost:3000` and the Loki API at `http://localhost:3100`

#### Scenario: Importer not started by default
- **WHEN** the user runs `docker compose up -d`
- **THEN** the metrics importer does not run as part of startup

### Requirement: Localhost-only exposure
Prometheus, Loki and Grafana ports SHALL bind to the loopback interface only, so other hosts on the network cannot reach them.

#### Scenario: Remote access refused
- **WHEN** another machine on the LAN connects to the host's port 9090, 3100 or 3000
- **THEN** the connection is refused

### Requirement: Data persistence across restarts
Prometheus time-series data, Loki log data and Grafana state SHALL survive container restarts and `docker compose down`. They are removed only when the user explicitly deletes the volumes.

#### Scenario: Restart keeps data
- **WHEN** data has been imported and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** the previously imported series are still queryable

#### Scenario: Restart keeps Loki entries
- **WHEN** entries have been pushed to Loki and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** the previously pushed entries are still queryable in Loki

#### Scenario: Explicit reset
- **WHEN** the user runs `docker compose down -v`
- **THEN** all stored time series, Loki entries and Grafana state are removed

### Requirement: Grafana datasource provisioned
Grafana SHALL start with a default Prometheus datasource that points to the stack's Prometheus, and a Loki datasource that points to the stack's Loki, with no manual configuration.

#### Scenario: Datasource available on first login
- **WHEN** the user logs into Grafana for the first time
- **THEN** a Prometheus datasource exists, is the default, and its connection test succeeds

#### Scenario: Loki datasource available on first login
- **WHEN** the user logs into Grafana for the first time
- **THEN** a Loki datasource exists and its connection test succeeds

## ADDED Requirements

### Requirement: Loki accepts and keeps historical entries
Loki SHALL accept entries pushed to its standard push API (`/loki/api/v1/push`) whatever their age and whatever order they arrive in, within a stream too. It SHALL keep them for a retention period defaulting to 10 years, configurable in `.env`. Queries SHALL be able to span the whole retention period. Entries dated more than one day in the future SHALL be rejected.

#### Scenario: Old entries accepted
- **WHEN** entries dated two years ago are pushed with default settings
- **THEN** they are accepted and queryable

#### Scenario: Older entries after newer ones
- **WHEN** entries from 2025 have been pushed to a stream, and entries from 2023 are then pushed to the same stream, including after a Loki restart
- **THEN** the 2023 entries are accepted and queryable

#### Scenario: Multi-year query
- **WHEN** the user queries a stream over a 3-year time range
- **THEN** Loki returns the entries in that range instead of a query-length error

#### Scenario: Future entry rejected
- **WHEN** a push contains a valid entry and an entry dated 3 days in the future
- **THEN** the future entry is rejected and the valid one is stored
