# Bachelor Thesis Lab

This repository provides a reproducible memory-analysis lab for three password
managers: Bitwarden, Vaultwarden, and Passbolt. It creates known test data,
runs controlled scenarios, dumps container processes with `gcore`, archives
artifacts, and restores a clean baseline between runs.

The scripts are experimental and are intended for disposable VMs described in
[lab-versions.md](./lab-versions.md), not for production environments.

## Prerequisites

- Ubuntu VM with Docker Engine and the Docker Compose plugin.
- Rootless Docker setup where applicable.
- `gdb`, `git`, `curl`, `wget`, `jq`, `unzip`, `uuid-runtime`, Python 3, and
  `sudo`.
- For Passbolt database extraction, `python3-pymysql` is installed by
  `runbook/02_1_passbolt_setup.sh`.
- For Bitwarden database extraction,
  `runbook/02_01_bitwarden_service_setup.sh` installs the Microsoft ODBC Driver
  18 for SQL Server and the `python3-pyodbc` package.

Run setup commands from the repository root unless stated otherwise.

## VM Setup

Run the common setup:

```bash
sudo ./runbook/01_vm_setup.sh
```

Then follow the setup for the selected password manager.

### Bitwarden

Create the `bitwarden` service user and repository location:

```bash
sudo ./runbook/02_00_bitwarden_user_setup.sh
sudo -iu bitwarden
```

The script clones the repository to `/opt/bitwarden/repo`. From there, configure
and start the service:

```bash
HOST_USER=<host-user> HOST_DOMAIN=<host-or-ip> \
  ./runbook/02_01_bitwarden_service_setup.sh
```

This installs Microsoft ODBC Driver 18, starts Bitwarden, copies its certificate
to the host, and sets `SERVICE_CHOICE=1`.

Complete the manual DNS/certificate steps and create an account as instructed
by the script.

### Vaultwarden

```bash
HOST_USER=<host-user> HOST_DOMAIN=<host-or-ip> \
  ./runbook/02_2_vaultwarden_setup.sh
```

The script copies the Compose configuration to `~/vaultwarden`, starts Caddy
and Vaultwarden, and copies Caddy's root certificate to the host.

Complete the manual DNS/certificate steps and create an account.

### Passbolt

```bash
HOST_USER=<host-user> HOST_DOMAIN=<host-or-ip> \
  ./runbook/02_1_passbolt_setup.sh
```

The script creates or reuses certificates and Compose configuration, starts
Passbolt, and sends a registration invitation.

Complete the DNS/certificate setup, open `https://passbolt.lab`, and finish
registration.

## CLI Setup

### Bitwarden CLI

For Bitwarden or Vaultwarden:

```bash
./runbook/03_bw_cli_setup.sh
```

Choose the service and optionally enable API-key/2FA login.

For API-key login, provide:

- `BW_CLIENTID`
- `BW_CLIENTSECRET`
- the account master password

The script stores these values in `~/.bashrc`, reloads it, logs in with
`bw login --apikey`, and unlocks with `bw unlock --passwordenv BW_PASSWORD`.
For normal login, the scripts continue to use the email and master password.

### Passbolt CLI

After registration:

```bash
./runbook/03_passbolt_cli_setup.sh
```

The script asks for the location of the private key and optionally enables
non-interactive TOTP 2FA. If enabled, it saves `PASSBOLT_MFA_MODE` and
`PASSBOLT_MFA_TOTP_TOKEN` in `~/.bashrc` and configures Passbolt with
`--mfaMode non-interactive-totp --mfaTotpToken <secret>`.

## Create Test Data and Baseline

Create the known test items for all three services:

```bash
./runbook/04_generate_test_items.sh
```

This creates login data, folders, attachments where supported, secure notes,
cards, identities, and marker values. Optionally add disposable data manually
before creating the baseline.

Back up and restore the populated baseline:

```bash
./runbook/05_backup_current_state.sh
```

The script preserves CLI settings and service state, with Passbolt MFA settings
included when configured.

## Running Scenarios

Run all scenarios:

```bash
./scripts/run-all.sh
```

Run selected scenarios:

```bash
./scripts/run-all.sh 1 4 7
./scripts/run-all.sh s4 s5 s6
```

Repeat selected scenarios:

```bash
./scripts/run-all.sh --repeat 3 1 2 3
./scripts/run-all.sh -n 3
```

The unified dispatcher is [scripts/scenario.sh](./scripts/scenario.sh). It can
also run scenarios directly:

```bash
./scripts/scenario.sh 1 4 7
./scripts/scenario.sh
```

Each scenario starts or resets the selected service, performs its operation,
dumps all configured container processes, and runs cleanup. Cleanup restores
the baseline and archives run-specific state.

Core dumps and related files are written under `artifacts/`. A dump name
contains the scenario and target container, for example:

```text
20261124-010000_S4_core.bitwarden-api
```

## Memory Analysis

### Restore the split artifact archives

The provided artifacts are split into consecutive archive parts. Reassemble
each ZIP before extracting it.

For the Bitwarden artifacts:

```bash
mkdir -p artifacts-bw-extracted
cat artifacts-bw/artifacts-bw.zip.part-* > artifacts-bw/artifacts-bw.zip
unzip -t artifacts-bw/artifacts-bw.zip
unzip -q artifacts-bw/artifacts-bw.zip -d artifacts-bw-extracted
```

For the Passbolt artifacts:

```bash
mkdir -p artifacts-passbolt-extracted
cat artifacts-passbolt/artifacts-passbolt.zip.part-* > artifacts-passbolt/artifacts-passbolt.zip
unzip -t artifacts-passbolt/artifacts-passbolt.zip
unzip -q artifacts-passbolt/artifacts-passbolt.zip -d artifacts-passbolt-extracted
```

On macOS, the shell expands the `part-*` files in filename order. Keep all
parts in the directory and do not rename or omit them.

From the repository root:

```bash
python3 -m scripts.memory_analysis \
  --core-dir artifacts \
  --markers ../artifacts/marker_log.csv \
  --database <sqlite-path> \
  --db-value users.password_hash \
  --db-value users.salt
```

For one baseline core dump:

```bash
python3 -m scripts.memory_analysis \
  --core-dir artifacts \
  --baseline artifacts/<baseline-core-file>
```

For a multi-container baseline, repeat `--baseline` for each container:

```bash
python3 -m scripts.memory_analysis \
  --core-dir artifacts \
  --baseline artifacts/<baseline-api-core> \
  --baseline artifacts/<baseline-identity-core> \
  --baseline artifacts/<baseline-mssql-core>
```

The script can also accept a glob for `--baseline`:

```bash
python3 -m scripts.memory_analysis \
  --core-dir artifacts \
  --baseline 'artifacts/*S1_core*'
```

It writes sorted strings, GNU-diff baseline/previous comparisons, marker
results, database-value representation searches, and JWT-like matches to
`../artifacts/` by default. JWT rows contain recovered token text and should
be protected as sensitive analysis data.

## Database Classification

For SQLite:

```bash
python3 -m scripts.classify_database \
  --database <database.db> \
  --output ../artifacts/column_classification.csv
```

The classifier reports populated SQLite table columns, observed formats,
thesis categories, and manual-review flags. It also supports SQL Server and
MariaDB through the shared database arguments.

Categories are:

- **P** plaintext personal data
- **S** plaintext security-relevant secret
- **V** password verifier
- **K** wrapped or encrypted key material
- **C** ciphertext
- **M** metadata

Format matches are not proof of encryption or key purpose. Ambiguous columns
must be reviewed with the database schema and password-manager version.

## Troubleshooting

- If a run stops halfway, rerun it; startup detects stale Compose containers
  and stops them before starting the service again.
- Bitwarden or Vaultwarden CLI connection problems: verify
  `NODE_EXTRA_CA_CERTS`, `bw config server`, `SERVICE_CHOICE`, and certificate
  trust.
- API-key login problems: verify `BW_CLIENTID`, `BW_CLIENTSECRET`,
  `BW_PASSWORD`, and `bw unlock --passwordenv BW_PASSWORD --raw`.
- Passbolt CLI/TOTP problems: verify `PASSBOLT_MFA_MODE`,
  `PASSBOLT_MFA_TOTP_TOKEN`, and `passbolt verify`.
- If baseline restore fails, rerun `05_backup_current_state.sh` after confirming
  the intended baseline state.

## Scenario Overview

| Scenario | Description |
|----------|-------------|
| S1 | Start the service and dump configured process memory |
| S2 | Log in and dump configured process memory |
| S3 | Lock the vault or open a secret through Passbolt and dump process memory |
| S4 | Create a test item and dump process memory |
| S5 | Edit a test item and dump process memory |
| S6 | Delete a test item and dump process memory |
| S7 | Retrieve or list a test item and dump process memory |
