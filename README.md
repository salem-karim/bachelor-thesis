# Bachelor thesis lab

This repository contains a reproducible Vaultwarden memory-analysis lab. The
workflow creates known test data, runs controlled scenarios, captures container
process memory, archives logs, and restores a clean baseline between scenarios.
The scripts are intended for the VM described in [lab-versions.md](./lab-versions.md),
not for a production password manager.

## Prerequisites

- The VM needs Docker Engine with the Compose plugin, rootless Docker, `gdb`,
  `curl`, `wget`, `unzip`, `jq`, Python 3, and `sudo`.
- Run commands from the repository root unless a command says otherwise.

## One-time VM setup

Run these steps in order on the VM:

1. Install operating-system, Docker, rootless-Docker, and `gdb` dependencies:
   `sudo ./runbook/01-vm-setup.sh`.
2. Start Vaultwarden and Caddy. Set the host values first:
   `HOST_USER=<host-user> HOST_DOMAIN=<host-or-ip> ./runbook/02-vaultwarden-setup.sh`.
   The script copies the Compose files into `~/vaultwarden`, starts the
   services, and copies Caddy's local CA certificate to `/tmp/caddy-root.crt`.
3. **Manual host step:** copy `/tmp/caddy-root.crt` to the analysis host's
   trusted CA directory and run its certificate update command. Add
   `vaultwarden.lab` to DNS or `/etc/hosts`, pointing at the VM. Verify that
   `https://vaultwarden.lab` opens without a certificate warning.
4. Configure the Bitwarden CLI and log in:
   `./runbook/03-bw-cli-setup.sh`.
   Choose Vaultwarden when prompted. The script sets `COMPOSE_FILE`,
   `SERVICE_CHOICE`, `PATH`, and `NODE_EXTRA_CA_CERTS` for later shells; start
   a new shell or source `~/.bashrc` afterward.
5. Create the known test items:
   `cd runbook && ../runbook/04-generate-test-items.sh`.
   This creates logins, folder data, an attachment, secure note, card,
   identity, and marker values used by the scenarios.
6. **Manual data-enrichment step (recommended):** add additional disposable
   items, folders, notes, and attachments in the web UI or CLI. A fuller vault
   gives the database classifier more columns and values to inspect.
7. Back up that populated state as the scenario baseline:
   `./runbook/05-backup-current-state.sh`.
   Do this only after the manual additions. The script archives the current
   service state and Bitwarden CLI state, then restores the baseline between
   runs.

## Running scenarios

After setup and baseline creation, run all scenarios:

```bash
./scripts/run-all.sh
```

Run selected scenarios, repeat them, and choose the amount of times they should run:

```bash
./scripts/run-all.sh 1 4 7
./scripts/run-all.sh --repeat 3 1 2 3
./scripts/run-all.sh -n 3
```

Each scenario starts the Compose services, performs its data operation, dumps
the target process with `gcore`, and calls cleanup. Cleanup archives the Caddy
log, stops Compose, logs out the CLI, archives run-specific state, and restores
the baseline. If a previous run was interrupted, the shared startup helper
detects running Compose containers and runs `docker compose down` before
starting them again.

The scenario scripts write core dumps and related files under `artifacts/`.
Use the generated filenames to identify the scenario (`S1` through `S7`) and
run timestamp.

## Analysis

Run analysis from the generated artifact directory (or pass explicit paths):

```bash
cd artifacts
python3 ../scripts/memory_analysis.py \
  --core-dir . \
  --baseline <baseline-core> \
  --markers ../marker_log.csv \
  --database <path-to-sqlite-db> \
  --db-value users.password_hash \
  --db-value users.salt
```

The script writes sorted strings, baseline/previous diffs, marker results,
database-value representation searches (raw, hexadecimal, standard Base64,
and URL-safe Base64), and `jwt_search.csv`. JWT rows include
the recovered JWT-like token text and offset; protect this output accordingly.
Marker and database-value reports intentionally record hashes/counts rather
than recovered marker or database values.

Classify a SQLite database with:

```bash
python3 scripts/classify_database.py <database.db> \
  --output artifacts/column_classification.csv
```

The classifier enumerates every SQLite table and column and reports populated
values, observed formats, a thesis category, and a `manual_review` flag. The
categories are **P** (plaintext personal data), **S** (plaintext
security-relevant secret), **V** (password verifier), **K** (wrapped/encrypted
key material), **C** (ciphertext), and **M** (metadata). EncString-shaped
values and nested EncStrings in JSON are detected, but format matching does
not prove cryptographic protection; interpret the report with the schema and
Vaultwarden version. The SQLite database is the primary input. Preserve the
database WAL, RSA key file, attachment files, and configuration file in the
same artifact run for the persistent-storage review.

## Reset and troubleshooting

If a run stops halfway, check `docker compose ps` in `~/vaultwarden` and rerun
the scenario; startup will stop stale running containers first. Do not delete
the baseline directories unless you intend to rebuild the experiment.

If HTTPS fails, repeat the manual certificate-trust and hosts/DNS steps.
If the CLI cannot connect, verify `NODE_EXTRA_CA_CERTS`, `bw config server`,
the selected service profile, and that Caddy is running. If a baseline error is
reported, rerun `05-backup-current-state.sh` after restoring the desired
manual test data.

## Scenario overview

| Scenario | Description |
|----------|-------------|
| S1 | Start the container and dump the server process |
| S2 | Log in and dump the server process |
| S3 | Lock the vault and dump the server process |
| S4 | Create an item and dump the server process |
| S5 | Edit an item and dump the server process |
| S6 | Delete an item and dump the server process |
| S7 | List an item and dump the server process |
