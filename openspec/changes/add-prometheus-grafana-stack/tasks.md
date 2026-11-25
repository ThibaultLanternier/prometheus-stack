# Tasks

## 1. Project scaffolding

- [x] 1.1 Create the D1 directory layout with `.gitkeep` files in `import/`, `import/processed/` and `import/failed/`, and verify `ls -R` shows every expected path
- [x] 1.2 Add `.gitignore` (ignoring `.env`, `import/*.om`, `import/processed/*.om`, `import/failed/*.om`) and `.env.example` with every variable from D1/D6/D8 set to its default or a placeholder; verify `git check-ignore .env import/x.om` lists both paths

## 2. Prometheus service

- [x] 2.1 Write `prometheus/prometheus.yml` (self-scrape only) and verify `docker run --rm --entrypoint promtool -v $PWD/prometheus:/p prom/prometheus:<tag> check config /p/prometheus.yml` succeeds
- [x] 2.2 Add the `prometheus` service to `docker-compose.yml` (pinned tag, D6 flags, `prometheus-data` volume, loopback-bound port, readiness healthcheck); verify `docker compose config -q` passes and, after `docker compose up -d prometheus`, `curl -s localhost:9090/-/ready` returns ready
- [x] 2.3 Verify the env wiring: with `PROMETHEUS_RETENTION=30d` in `.env`, `curl -s localhost:9090/api/v1/status/runtimeinfo` reports a 30d retention, and with no `.env` it reports 10y
- [x] 2.4 Verify loopback-only exposure: `ss -ltnp | grep 9090` shows `127.0.0.1:9090`, not `0.0.0.0`

## 3. Grafana service and provisioning

- [x] 3.1 Write the datasource provisioning file (`uid: prometheus`, default, `http://prometheus:9090`) and the dashboard provider file
- [x] 3.2 Add the `grafana` service (pinned tag, admin credentials from `.env`, `grafana-data` volume, provisioning mounts, loopback port, healthcheck, `depends_on` prometheus healthy); verify `docker compose up -d` brings both services to healthy
- [x] 3.3 Verify provisioning: `curl -su admin:<pw> localhost:3000/api/datasources/uid/prometheus/health` returns status OK, and the configured admin password is accepted

## 4. Sample data and import file format

- [x] 4.1 Generate `examples/sample.om`: 2–3 gauge series with labels, one day in early 2024 at 5-minute steps, grouped by metric and series, timestamps ascending, ending with `# EOF`; verify `promtool tsdb create-blocks-from openmetrics examples/sample.om <tmpdir>` (inside the image) succeeds
- [x] 4.2 Create `grafana/dashboards/sample.json` with panels for the sample series, using datasource UID `prometheus` and a fixed time range matching the sample; verify the dashboard appears in Grafana's `/api/search` after restart
- [x] 4.3 Write the README section "Import file format" (OpenMetrics syntax, seconds timestamps, `# EOF`, ordering, naming, label/cardinality guidance, lookback note) and verify its example snippet passes promtool when saved as a file

## 5. Importer

- [x] 5.1 Implement the validation pre-pass in `scripts/import.sh` (D3: EOF check, ms/far-future timestamp check), and verify by hand that it rejects a file without `# EOF` and a file with ms timestamps and accepts `examples/sample.om`
- [x] 5.2 Implement the import loop (D4/D5: clean leftover staging, run promtool into `.staging/<run-id>`, chown to 65534, atomic `mv` into `/prometheus`, move file to `processed/` or `failed/`, print errors, keep going, "nothing to import" message, non-zero exit if any file failed)
- [x] 5.3 Add the `importer` service (profile `import`, same image tag, `user: "0:0"`, D2 mounts); verify `docker compose up -d` does not start it and `docker compose run --rm importer` with `examples/sample.om` copied into `import/` moves the file to `processed/`
- [x] 5.4 Verify the queryable bound: within 2 minutes of 5.3, `curl 'localhost:9090/api/v1/query?query=<sample_metric>&time=<sample_ts>'` returns the sample value without restarting Prometheus, and the sample dashboard shows the data. If not, apply the D-risk fallback (print a restart hint) and document it
- [ ] 5.5 Verify persistence: after `docker compose down && docker compose up -d`, the 5.4 query still returns the value
- [ ] 5.6 Write the README sections "Importing data" (command, folders, failure handling, restart fallback) and "Resetting" (`down -v`), and verify each documented command runs as written

## 6. End-to-end smoke test

- [ ] 6.1 Implement `scripts/smoke-test.sh` per D9 (isolated project name, alternate ports, temp `IMPORT_DIR`, good + no-EOF + ms-timestamp fixtures, assertions on exit code, folders, query within 120 s, Grafana datasource health, idempotent re-run, `down -v` trap); verify it exits 0 on a clean machine and leaves no `prom-smoke` containers or volumes behind
- [ ] 6.2 Verify the smoke test does not touch the user's stack: run it while the main stack is up and confirm the main stack's data and `./import` folder are unchanged
- [ ] 6.3 Add a README "Testing" section describing `scripts/smoke-test.sh`

## 7. Lint

- [ ] 7.1 Run `shellcheck` (via the `koalaman/shellcheck` image) on `scripts/*.sh`, `docker compose config -q`, and `promtool check config`; fix all findings and verify that all three pass cleanly and the smoke test still passes

## Workflow follow-up

- Initialise git with a `develop` branch and a remote before implementation, then work on a feature branch.
- Open the PR against `develop` once all tasks are checked.
- Archive the change with `/opsx:archive` after the PR is merged.
