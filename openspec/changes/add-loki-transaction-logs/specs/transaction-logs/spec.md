# Spec Delta

## Purpose

Lets the user load bank transactions from JSON Lines files into the local Loki and explore them in Grafana by date and account, with free-text search on their descriptions.

## ADDED Requirements

### Requirement: Accepted transaction file format
Ingestion SHALL accept JSON Lines files with the `.jsonl` extension: one JSON object per non-empty line. Each object has `id`, `date`, `account`, `type`, `amount` and `description`. Any other fields are optional and kept. The format SHALL be documented, with a valid sample file included in the repository.

#### Scenario: Valid file ingested
- **WHEN** a `.jsonl` file whose lines all carry the required fields is placed in `./import-transactions/` while the stack is running
- **THEN** every transaction in it becomes queryable in Loki, including its optional fields

### Requirement: Invalid lines dropped individually
A line that is not a JSON object, lacks a required field, has an invalid `date` or carries a non-conforming `account` or `type` SHALL NOT be stored. The other lines of the same file SHALL still be stored. Each dropped line SHALL be counted under a reason that identifies the rule it broke.

#### Scenario: One bad line among good ones
- **WHEN** a file of 10 lines in which one line has no `amount` is placed in the folder
- **THEN** the 9 valid transactions are stored and the invalid one is not
- **AND** the dropped-lines count for the missing-field reason increases by 1

#### Scenario: Malformed JSON line
- **WHEN** a file contains a line that is not a valid JSON object
- **THEN** that line is not stored, it is counted as dropped, and the other lines are stored

### Requirement: Dropped lines visible
Dropped lines SHALL be visible without reading container logs. The Transactions dashboard SHALL show the number of lines dropped per reason during the last 7 days of ingestion activity. This window does not depend on the dashboard's time range, which selects transaction dates.

#### Scenario: Drop shown on the dashboard
- **WHEN** a line was dropped for an invalid date in the last hour, and the dashboard's time range is set to January 2025
- **THEN** the Transactions dashboard shows at least one dropped line under the invalid-date reason

### Requirement: Transaction timestamps
A transaction's timestamp in Loki SHALL come from `date`. It is either a calendar date `YYYY-MM-DD`, stored at 00:00 UTC that day, or an ISO 8601 date-time with a UTC offset, stored at that instant. A line whose `date` has neither form, or lies more than one day in the future, SHALL be dropped. It SHALL never be stored with a timestamp other than its `date`, such as the time it was read.

#### Scenario: Date-only transaction
- **WHEN** a transaction has `"date": "2025-01-03"`
- **THEN** it appears in Loki at 2025-01-03T00:00:00Z

#### Scenario: Date with time and offset
- **WHEN** a transaction has `"date": "2025-01-03T14:22:00+01:00"`
- **THEN** it appears in Loki at 2025-01-03T13:22:00Z

#### Scenario: Invalid date dropped
- **WHEN** a transaction has `"date": "03/01/2025"`
- **THEN** it is not stored at any timestamp and is counted as dropped

### Requirement: Low-cardinality, non-identifying labels
Each transaction SHALL be indexed by exactly three labels: a fixed `job="transactions"`, plus `account` and `type`. `account` SHALL match `^[a-z][a-z0-9_-]{0,63}$` and SHALL NOT contain six or more consecutive digits, so real account numbers and IBANs cannot become labels. `type` SHALL match `^[A-Z][A-Z0-9_]{0,31}$`. A line with a non-matching value SHALL be dropped.

#### Scenario: Account number rejected as account
- **WHEN** a transaction has `"account": "00021429861"` or `"account": "fr7630001007941234567890185"`
- **THEN** it is not stored, and it is counted as dropped under the invalid-account reason

#### Scenario: Labels available for filtering
- **WHEN** transactions for accounts `courant` and `livret_joint` have been ingested
- **THEN** Loki lists `courant` and `livret_joint` as values of the `account` label

### Requirement: Whole transaction kept as the log line
Each stored transaction SHALL be stored as its original JSON object, with every field it had, as the log line. Every field SHALL then be extractable at query time.

#### Scenario: Field extraction at query time
- **WHEN** a transaction with `"amount": -42.5` and `"currency": "EUR"` has been ingested
- **THEN** a LogQL query with the `json` parser can filter on `amount` and display `currency` for that transaction

### Requirement: Automatic ingestion from the watched folder
While the stack is running, every `.jsonl` file placed in `./import-transactions/` SHALL be ingested without any command. Its transactions SHALL become queryable within 1 minute. Lines appended to an already ingested file SHALL be ingested too. Files SHALL be left in place. A file already read SHALL NOT be read again after a restart of the stack.

#### Scenario: File dropped while stack is running
- **WHEN** the user copies two `.jsonl` files into `./import-transactions/`
- **THEN** within 1 minute the transactions of both files are queryable, without stopping Loki, Prometheus or Grafana

#### Scenario: Restart does not re-read files
- **WHEN** files have been ingested and the user runs `docker compose down` followed by `docker compose up -d`
- **THEN** no file is read again, and each transaction still appears once

#### Scenario: Ingestion not started by the metrics importer
- **WHEN** the user runs the metrics import command
- **THEN** transaction ingestion is unaffected

### Requirement: No duplicate transactions
Ingesting a transaction that is already stored, same `id` and byte-identical line, SHALL NOT create a second copy. Distinct transactions sharing a date, account, type, amount and description but with different `id`s SHALL all be stored.

#### Scenario: Overlapping export added
- **WHEN** a file is ingested, and later a second file containing some of the same transactions, written identically, is added
- **THEN** each of those transactions appears exactly once in query results

#### Scenario: Same file added under another name
- **WHEN** an already ingested file is copied into the folder under a new name
- **THEN** no transaction appears twice in query results

#### Scenario: Two identical purchases on the same day
- **WHEN** a file contains two transactions identical except for their `id`
- **THEN** both are stored and both appear in query results

### Requirement: Recovery after a Loki outage
If Loki is down for up to 5 minutes, transactions read in the meantime SHALL be delivered once it is back. For longer outages, a documented command SHALL re-ingest every file in the folder from the start without creating duplicates.

#### Scenario: Short outage
- **WHEN** Loki is stopped, a file is added, and Loki is started again within 5 minutes
- **THEN** the file's transactions become queryable once Loki is back

#### Scenario: Full re-ingestion
- **WHEN** the user runs the documented re-ingestion command
- **THEN** every file in `./import-transactions/` is read again from the start, and each transaction still appears once

### Requirement: Historical transactions accepted and kept
Loki SHALL accept transactions of any age, whatever order they are ingested in, and keep them for a retention period defaulting to 10 years, configurable in `.env`. Queries SHALL be able to span the whole retention period.

#### Scenario: Old transactions ingested
- **WHEN** a file with transactions dated two years ago is added with default settings
- **THEN** all its transactions are accepted and queryable

#### Scenario: Older history ingested after newer data
- **WHEN** transactions from 2025 for an account have been ingested and the user then adds transactions from 2023 for the same account
- **THEN** the 2023 transactions are accepted and queryable

#### Scenario: Multi-year query
- **WHEN** the user queries one account over a 3-year time range
- **THEN** Loki returns the transactions in that range instead of a query-length error

### Requirement: Browsing and searching transactions in Grafana
Grafana SHALL provision a **Transactions** dashboard. It filters by `account` and `type` (each with an "all" choice), searches descriptions case-insensitively with a free-text box, and shows each matching transaction as one readable line with date, account, type, amount and description. It SHALL show at least 5,000 transactions for the selected range.

#### Scenario: Filter by account and date
- **WHEN** the user selects account `courant` and a time range of January 2025 on the dashboard
- **THEN** only transactions of `courant` dated in January 2025 are listed

#### Scenario: Text search
- **WHEN** the user types `supermarche` in the search box
- **THEN** only transactions whose line contains `SUPERMARCHE`, case-insensitively, are listed

#### Scenario: Sample data visible
- **WHEN** the sample transactions file has been ingested and the user opens the dashboard over the sample's time range
- **THEN** the sample transactions are listed
