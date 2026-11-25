# Spec Delta

## Purpose

Lets the user load bank transactions from JSON Lines files into the local Loki and explore them in Grafana by date and account, with free-text search on their descriptions.

## ADDED Requirements

### Requirement: Accepted transaction file format
The importer SHALL accept JSON Lines files with the `.jsonl` extension: one JSON object per non-empty line. Each object has `id`, `date`, `account`, `type` and `description` as non-empty strings and `amount` as a JSON number. Any other fields are optional and kept. The format SHALL be documented, with a valid sample file included in the repository.

#### Scenario: Valid file imported
- **WHEN** a `.jsonl` file whose lines all carry the required fields is placed in `./import-transactions/` and the import runs
- **THEN** every transaction in it becomes queryable in Loki, including its optional fields

#### Scenario: Missing required field rejected
- **WHEN** a file contains a line without `amount`
- **THEN** the importer reports that file as invalid, names the line and the missing field, and imports none of its transactions

#### Scenario: Malformed JSON rejected
- **WHEN** a file contains a line that is not a valid JSON object
- **THEN** the importer reports that file as invalid, names the line, and imports none of its transactions

### Requirement: Transaction timestamps
The transaction's timestamp in Loki SHALL come from `date`. It is either a calendar date `YYYY-MM-DD`, stored at 00:00 UTC that day, or an ISO 8601 date-time with a UTC offset, stored at that instant. A file with an unparseable date, or with a date more than one day in the future, SHALL be rejected.

#### Scenario: Date-only transaction
- **WHEN** a transaction has `"date": "2025-01-03"`
- **THEN** it appears in Loki at 2025-01-03T00:00:00Z

#### Scenario: Date with time and offset
- **WHEN** a transaction has `"date": "2025-01-03T14:22:00+01:00"`
- **THEN** it appears in Loki at 2025-01-03T13:22:00Z

#### Scenario: Invalid date rejected
- **WHEN** a file contains a transaction with `"date": "03/01/2025"`
- **THEN** the importer reports that file as invalid and imports none of its transactions

### Requirement: Low-cardinality, non-identifying labels
Each transaction SHALL be indexed by exactly three labels: a fixed `job="transactions"`, plus `account` and `type`. `account` SHALL match `^[a-z][a-z0-9_-]{0,63}$` and SHALL NOT contain six or more consecutive digits, so real account numbers and IBANs cannot become labels. `type` SHALL match `^[A-Z][A-Z0-9_]{0,31}$`. A file with a non-matching value SHALL be rejected.

#### Scenario: Account number rejected as account
- **WHEN** a transaction has `"account": "00021429861"` or `"account": "fr7630001007941234567890185"`
- **THEN** the importer reports that file as invalid and explains that `account` must be a short readable name

#### Scenario: Labels available for filtering
- **WHEN** transactions for accounts `courant` and `livret_joint` have been imported
- **THEN** Loki lists `courant` and `livret_joint` as values of the `account` label

### Requirement: Whole transaction kept as the log line
Each transaction SHALL be stored as its original JSON object, with every field it had, as the log line. Every field SHALL then be extractable at query time.

#### Scenario: Field extraction at query time
- **WHEN** a transaction with `"amount": -42.5` and `"currency": "EUR"` has been imported
- **THEN** a LogQL query with the `json` parser can filter on `amount` and display `currency` for that transaction

### Requirement: On-demand transaction import trigger
The user SHALL trigger a transaction import with a single documented command while the stack is running. The command processes every pending `.jsonl` file in `./import-transactions/`, and the transactions become queryable within 1 minute of the command finishing successfully.

#### Scenario: Import while stack is running
- **WHEN** Loki is running and the user runs the documented command with two pending files
- **THEN** both files are imported without stopping Loki, Prometheus or Grafana
- **AND** their transactions are queryable within 1 minute

#### Scenario: Nothing to import
- **WHEN** the user runs the command and `./import-transactions/` has no pending `.jsonl` files
- **THEN** the command reports that nothing was imported and exits successfully

### Requirement: Processed and failed transaction files
Each successfully imported file SHALL move to `./import-transactions/processed/`. A file that fails validation SHALL import nothing and move to `./import-transactions/failed/`. The command SHALL print each error, continue with the remaining files, and exit with a non-zero status if any file failed. An existing file in either folder SHALL never be overwritten.

#### Scenario: One bad file among good ones
- **WHEN** the import runs over one valid file and one file with a missing field
- **THEN** the valid file's transactions are imported and the file moves to `processed/`
- **AND** the invalid file moves to `failed/`, its error is printed, and the command exits non-zero

#### Scenario: Same file name imported twice
- **WHEN** a file named `2025-01.jsonl` is imported while `processed/2025-01.jsonl` already exists
- **THEN** both files are kept in `processed/` under distinct names

### Requirement: No duplicate transactions
Importing a transaction that is already stored, same `id` and same content, SHALL NOT create a second copy. Distinct transactions sharing a date, account, type, amount and description but with different `id`s SHALL all be stored. Within one file, a repeated `id` SHALL make the file invalid.

#### Scenario: Overlapping export imported again
- **WHEN** a file is imported, and later a second file containing some of the same transactions, unchanged, is imported
- **THEN** each of those transactions appears exactly once in query results

#### Scenario: Two identical purchases on the same day
- **WHEN** a file contains two transactions identical except for their `id`
- **THEN** both are stored and both appear in query results

#### Scenario: Duplicate id within a file
- **WHEN** a file contains two lines with the same `id`
- **THEN** the importer reports that file as invalid and imports none of its transactions

### Requirement: Safe retry after a failed push
If Loki becomes unreachable or rejects a push partway through a file, the file SHALL move to `failed/` with an error saying it may be partly imported. Moving it back to `./import-transactions/` and running the import again SHALL complete it without creating duplicates.

#### Scenario: Loki unavailable during import
- **WHEN** the import command runs while Loki is stopped
- **THEN** the command waits for Loki for a bounded time, then fails with a clear message, moves pending files to `failed/`, and exits non-zero

### Requirement: Historical transactions accepted and kept
Loki SHALL accept transactions of any age, whatever order they are imported in, and keep them for a retention period defaulting to 10 years, configurable in `.env`. Queries SHALL be able to span the whole retention period.

#### Scenario: Old transactions imported
- **WHEN** a file with transactions dated two years ago is imported with default settings
- **THEN** all its transactions are accepted and queryable

#### Scenario: Older history imported after newer data
- **WHEN** transactions from 2025 for an account have been imported and the user then imports transactions from 2023 for the same account
- **THEN** the 2023 transactions are accepted and queryable

#### Scenario: Year-long query
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
- **WHEN** the sample transactions file has been imported and the user opens the dashboard over the sample's time range
- **THEN** the sample transactions are listed
