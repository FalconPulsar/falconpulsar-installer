# Upgrade rehearsal using FalconPulsar's backup tools

The backup remains FalconPulsar's native format. Use **Configuration Backup → Export** in the desktop menu, or `fp config export`, for encrypted `.fpconfig` configuration. Use **`fp backup`** for the full data archive, including Core, Gateway, Engine and Copilot stores. Configuration export alone does not contain Core time-series history.

The new `fp-rehearse` helper validates that native archive and calls the application's existing `databackup.Restore` implementation. It does not call the installed stack's start/stop actions. Configuration is captured in a separate `captured-config` directory and is never launched.

## Prepare without stopping the installation

Build the current app CLI and the isolated restore helper from this repository's `console` directory. Choose a private artifacts directory outside every application data directory:

```sh
umask 077
mkdir -p /absolute/path/to/private-artifacts
cd /absolute/path/to/falconpulsar-installer/console
go build -o /absolute/path/to/private-artifacts/fp ./cmd/fp
go build -o /absolute/path/to/private-artifacts/fp-rehearse ./cmd/fp-rehearse
```

The native configuration export and inspect commands prompt for the existing administrator credentials. Do not put passwords in shell arguments or commit them:

```sh
FP_HOME=/absolute/path/to/installed-stack /absolute/path/to/private-artifacts/fp config export /absolute/path/to/private-artifacts/settings.fpconfig
FP_HOME=/absolute/path/to/installed-stack /absolute/path/to/private-artifacts/fp config inspect /absolute/path/to/private-artifacts/settings.fpconfig --json
```

Treat an incomplete export as a failed prerequisite. The data archive contains credentials and configuration without the `.fpconfig` encryption; keep its directory private. Record the running services' exact image IDs and preserve those images before any upgrade. Preserve the original installation files as well as the backup; the native data archive includes only its defined configuration file list, not every deployment artifact.

Capture representative **read-only FPQ** results from the old Core before stopping it. Prefer fixed historical windows, including old partitions, late arrivals and repeated timestamps. Put exact `rows` from the API response into a private checks JSON file. Its shape is:

```json
[
  {
    "query": "temperature@stable_fixture >> collect()",
    "limit": 100,
    "expected_row_count": 2,
    "expected_rows": [[1700000000000000000, 21.5], [1700000001000000000, 22.0]]
  }
]
```

Replace the example with actual baseline results. The limit must exceed the expected count so a capped response cannot pass as a complete result. Do not use changing relative windows for a stable baseline. The API may round numeric nanosecond timestamps; the separate file comparison verifies exact stored payload bytes.

## Production capture is a separate maintenance-window action

No production stop, backup, restore or deployment is performed by the rehearsal runner.

1. Quiesce ingestion and allow a sufficiently long graceful shutdown of the old stack. Preserve shutdown/checkpoint logs and verify there was no forced kill, I/O failure or incomplete flush. The current `fp stop` command invokes Compose `down`; plan the shutdown timeout and preserve logs before containers are removed.
2. Verify that **every retained WAL record was durably applied by the old Core**. A normal exit code, a sealed WAL or matching timestamps alone cannot establish this. If that condition cannot be established, do not assert it or run the legacy migration.
3. With the stores stopped and unchanged, run the app's native backup command:

   ```sh
   umask 077
   FP_HOME=/absolute/path/to/installed-stack /absolute/path/to/private-artifacts/fp backup /absolute/path/to/private-artifacts/clean-data.tar.gz
   /absolute/path/to/private-artifacts/fp-rehearse inspect --archive /absolute/path/to/private-artifacts/clean-data.tar.gz > /absolute/path/to/private-artifacts/archive-report.json
   ```

4. Keep the original archive and independent rollback copy. Resume the old installation only through the agreed maintenance procedure.

`fp backup` does **not** quiesce Core itself: its implementation walks the Core directory. Its manifest's current `crash-consistent` label is not evidence of a clean checkpoint, even when the operator actually captured stopped files. The inspection report deliberately leaves `core_clean_checkpoint_verified` false. The operator's separate verified checkpoint evidence is mandatory for legacy migration.

## Run the isolated rehearsal

Use an already built candidate Core image containing `falconpulsar-legacy-migrate`. The runner resolves its immutable local image ID and never pulls an image. Run from the installer repository:

```sh
python3 scripts/rehearse-upgrade.py \
  --archive /absolute/path/to/private-artifacts/clean-data.tar.gz \
  --destination /absolute/path/to/private-artifacts/rehearsal-001 \
  --helper /absolute/path/to/private-artifacts/fp-rehearse \
  --core-image falconpulsar-audit-core:local \
  --checks /absolute/path/to/private-artifacts/baseline-checks.json \
  --verified-clean-checkpoint
```

The destination must not exist. Existing Core credentials are prompted securely and used only against the isolated restored Core. For unattended disposable tests, `FP_REHEARSAL_USERNAME` and `FP_REHEARSAL_PASSWORD` may supply them; no credentials or tokens are included in reports.

Allow at least **three times the uncompressed archive contents, plus one archive copy and 1 GiB** of free space. Runtime growth, sparse files and unusually large SQLite WAL files can need additional space. The runner checks this estimate before restoring. Large full-store hashing and copying will take time.

The runner:

- Validates the complete native archive, paths, manifest, gzip footer and file hashes.
- Restores through the application's native restore code into a new private directory.
- Checks SQLite integrity and records table row counts on disposable copies, preserving the first restore byte-for-byte.
- Migrates a separate Core copy using the packaged tool. The source mount is read-only. It compares every file and permits differences only in the 16 FPF checkpoint-marker bytes; stored payloads and WAL files must remain exact.
- Boots the candidate twice, checks health, signs in and compares every requested result row and count, then verifies graceful exits.
- Restores the same archive again through the native tool and verifies every restored file, demonstrating that the original data remains recoverable.
- Removes its uniquely named containers and requires a successful Docker inventory check proving they are gone.

Containers have no external network, no published ports, a read-only root filesystem, dropped capabilities and no installed-stack mounts. Only the disposable candidate directory is writable. The default Core test limits are 2 GiB RAM, 2 CPUs and 128 processes; a resource failure fails the rehearsal and requires a reviewed adjustment, not a waived check.

Results are written to `rehearsal-result.json`, `restore-report.json`, `rollback-report.json`, and private migration/Core logs. Failure remains explicit and leaves the new rehearsal data available for diagnosis. The original archive is never overwritten.

## Rollback and deployment boundary

A successful result proves **Core/storage rehearsal**, not a complete deployment rehearsal. Full-stack service compatibility, live WebSockets, external providers and load testing are separate checks. The companion services' SQLite files are checked, but their applications are not launched by this runner.

The second native restore is the rollback rehearsal. For an eventual production rollback, preserve the failed installation, restore the original data with the original compatible binaries and pinned image IDs, and recheck the baseline before reopening ingestion. Do not open migrated data using an older Core binary.

The installed `fp restore` command stops **and automatically restarts** its configured stack. Do not use it as a rehearsal shortcut or run it against production until the rollback configuration and original image references are prepared. The isolated helper avoids that automatic lifecycle behavior. Production rollout and rollback execution require their own reviewed maintenance procedure.

## Local checks

```sh
cd console
go test ./...
cd ..
python3 scripts/test_rehearse_upgrade.py
```

The helper tests use `databackup.Backup` and `databackup.Restore` on disposable data, including WAL sidecars and malformed archives. The end-to-end rehearsal was also tested against a native `fp backup` archive containing an old-Core-generated fixture with eight known points.
