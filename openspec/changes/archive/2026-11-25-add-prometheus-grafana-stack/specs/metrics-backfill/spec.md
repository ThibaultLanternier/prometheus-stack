# Spec Delta

## Purpose

Lets the user load historical time series from OpenMetrics text files into the local Prometheus, so the data can be queried with PromQL and visualised in Grafana.

## ADDED Requirements

### Requirement: Accepted import file format
The importer SHALL accept OpenMetrics text files with the `.om` extension. Every sample carries a Unix timestamp in seconds (fractions allowed), and the last line is `# EOF`. The accepted format SHALL be documented, with a valid sample file included in the repository.

#### Scenario: Valid file imported
- **WHEN** a file whose samples have second-precision timestamps and that ends with `# EOF` is placed in `./import/` and the import runs
- **THEN** its series become queryable in Prometheus at the timestamps written in the file

#### Scenario: Missing EOF marker rejected
- **WHEN** a file without a trailing `# EOF` line is imported
- **THEN** the importer reports that file as invalid and imports none of its samples

#### Scenario: Millisecond timestamps rejected
- **WHEN** a file uses millisecond timestamps (e.g. `1732400000000`)
- **THEN** the importer reports that file as invalid instead of storing samples at a far-future date

### Requirement: On-demand import trigger
The user SHALL trigger an import with a single documented command, while the stack is running. The import processes every pending `.om` file in `./import/`.

#### Scenario: Import while stack is running
- **WHEN** Prometheus is running and the user runs the documented import command with two pending files
- **THEN** both files are imported without stopping Prometheus or Grafana

#### Scenario: Nothing to import
- **WHEN** the user runs the import command and `./import/` has no pending `.om` files
- **THEN** the command reports that nothing was imported and exits successfully

### Requirement: Imported data becomes queryable
Once an import completes successfully, the imported series SHALL become queryable through the Prometheus HTTP API within 2 minutes, without restarting Prometheus.

#### Scenario: Query after import
- **WHEN** the import command finishes successfully for the sample file
- **THEN** within 2 minutes an instant query for a sample metric at one of the file's timestamps returns the value from the file

### Requirement: Processed files are not re-imported
Each successfully imported file SHALL be moved to `./import/processed/`, so running the import again does not duplicate its data.

#### Scenario: Re-running import
- **WHEN** a file has been imported successfully and the user runs the import command again
- **THEN** that file is not imported a second time and is present in `./import/processed/`

### Requirement: Invalid files isolated
A file that fails to import SHALL leave the stored data unchanged and be moved to `./import/failed/`. The command SHALL show the parse error and continue with the remaining files. If any file failed, the command SHALL exit with a non-zero status.

#### Scenario: One bad file among good ones
- **WHEN** the import runs over one valid file and one malformed file
- **THEN** the valid file's series are imported and the file is moved to `./import/processed/`
- **AND** the malformed file is moved to `./import/failed/`, its error is printed, and the command exits non-zero

### Requirement: No partially written data exposed
Prometheus SHALL never load a partially written block. Data from a file SHALL be fully visible or not visible at all.

#### Scenario: Import interrupted
- **WHEN** the import process is killed while converting a file
- **THEN** Prometheus keeps serving queries normally and exposes no samples from the interrupted file
