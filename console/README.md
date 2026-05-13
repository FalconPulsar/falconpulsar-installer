# FalconPulsar `fp` console

Single static binary with two usage modes:

- **Pure CLI** (scriptable): `fp status`, `fp start`, `fp stop`, `fp logs`, `fp config export <file>`, …
- **Full-screen TUI** (Midnight-Commander style): run `fp` with no arguments.

Both modes share the same underlying operations — the TUI is just a visual
surface over the CLI's actions.

## Build

```sh
cd console
go build -o dist/fp ./cmd/fp
```

Cross-compile for Linux + macOS (from any host):

```sh
GOOS=linux   GOARCH=amd64 go build -o dist/fp-linux-amd64  ./cmd/fp
GOOS=linux   GOARCH=arm64 go build -o dist/fp-linux-arm64  ./cmd/fp
GOOS=darwin  GOARCH=arm64 go build -o dist/fp-macos-arm64  ./cmd/fp
GOOS=darwin  GOARCH=amd64 go build -o dist/fp-macos-amd64  ./cmd/fp
```

On **Windows**, `fp.exe` is NOT this binary — it's a tiny Go wrapper in
`windows/fp-wrapper/` that execs the Linux `fp` inside WSL. Build that
instead when producing release artifacts:

```sh
cd ../windows/fp-wrapper
GOOS=windows GOARCH=amd64 go build -o ../../console/dist/fp-windows-amd64.exe .
```

## Install target

The Linux/macOS installer drops the right binary at `$FP_HOME/bin/fp`
(`/home/<user>/falconpulsar/bin/fp` in per-user / WSL installs,
`/home/falconpulsar/bin/fp` in native-Linux service-user installs,
`~/falconpulsar/bin/fp` on macOS) and adds that directory to the user's
PATH. The install path is wired in `shared/lib/fpcli.sh`.

## Features

| Command | TUI equivalent | Notes |
|---|---|---|
| `fp status [--json]` | Services panel (live) | Exit code: 0 running, 1 stopped, 2 partial |
| `fp start` / `stop` / `restart` | F2 / F3 / F4 | docker compose wrappers |
| `fp logs [svc]` | F5 | tail -f via docker compose |
| `fp open` | — | xdg-open / open / start |
| `fp config edit <name>` | F6 | opens $EDITOR |
| `fp config export <file>` | F7 | admin-only, AES-256-GCM `.fpconfig` |
| `fp config import <file>` | F8 | admin-only, replaces config |
| `fp about` / `docs` / `request-feature` | Help menu | |
| `fp uninstall` | — | On Linux / macOS runs `linux/uninstall.sh` (copied to `$FP_HOME/uninstall.sh` at install). On WSL hands off to the Windows Inno Setup uninstaller (`unins000.exe`) via interop. |

## `.fpconfig` backup format

Identical binary envelope to `macos/menu-bar-app/FalconPulsar/ConfigBackup.swift`
and `windows/tray-app/ConfigBackup.cs`. Export on one platform, import on
another.

```
[0..3]   Magic "FPCF"
[4]      Format version (current: 2, accepts: 1, 2)
[5..20]  PBKDF2 salt (16 bytes)
[21..32] AES-GCM nonce (12 bytes)
[33..]   AES-256-GCM ciphertext of the zip payload
[tail 16 bytes] GCM auth tag
```

Key = `PBKDF2-HMAC-SHA256("<admin_user>:<admin_password>", salt, 100_000, 32)`.

### Payload (zip)

```
manifest.json                  format_version + fp_version + host + timestamp
files/compose.yml              docker compose for the stack
files/.env                     env vars (may contain secrets — encrypted)
files/gateway.yaml             AI Gateway config seed
api/roles.json                 GET /api/v1/roles
api/users.json                 GET /api/v1/users
api/asset-types.json           GET /api/v1/asset-types         (new in v2)
api/assets.json                GET /api/v1/assets
api/datasources.json           GET /api/v1/datasources
api/series.json                GET /api/v1/series              (new in v2; includes engineering + alarms)
api/mappings.json              GET /api/v1/mappings
api/relationships.json         GET /api/v1/relationships       (new in v2)
api/annotations.json           GET /api/v1/annotations         (new in v2)
```

### Format-version compatibility

| Reader \ File | v1 file | v2 file |
|---|---|---|
| v1 client (older release) | ✓ works | ✗ rejected (`unsupported backup format version 2`) |
| v2 client (this release)  | ✓ works (missing sections silently skipped) | ✓ full restore |

### Import behavior (v2)

On import, sections are applied in **dependency order**:

```
roles → asset-types → users → datasources → assets → series → mappings → relationships → annotations
```

For each item the client strips server-generated fields (`id`, `created_at`,
`updated_at`, `point_count`, `disk_bytes`, etc.) before POSTing — so the target
mints fresh IDs using the natural keys (`name`, `path`, `username`). Items
that conflict with already-existing records on the target (HTTP 409) are
counted as **skipped**, not errors; other failures are counted as errors and
the first 5 messages per section are surfaced in the CLI / TUI summary.

A successful run prints a per-section breakdown:

```
Import complete: 47 created, 3 skipped (already existed), 2 errors.
  • roles         created=2  skipped=0  errors=0
  • asset-types   created=5  skipped=0  errors=0
  • users         created=3  skipped=1  errors=0
  • datasources   created=4  skipped=0  errors=0
  • assets        created=12 skipped=0  errors=0
  • series        created=18 skipped=2  errors=1
      ! POST /api/v1/series: HTTP 400 (asset not found: foo.bar.baz)
  • mappings      created=3  skipped=0  errors=1
      ! POST /api/v1/mappings: HTTP 422 (series_id null)
```

## Admin-only operations

Export and Import require admin credentials. The binary calls
`POST /api/v1/auth/login` and then `GET /api/v1/auth/me` to verify the user
has the `admin` role before proceeding. Non-admins get:

    Error: only administrator accounts can perform this operation.
