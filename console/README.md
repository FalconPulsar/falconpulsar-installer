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

Cross-compile for Linux, macOS, Windows (from any host):

```sh
GOOS=linux   GOARCH=amd64 go build -o dist/fp-linux-amd64  ./cmd/fp
GOOS=linux   GOARCH=arm64 go build -o dist/fp-linux-arm64  ./cmd/fp
GOOS=darwin  GOARCH=arm64 go build -o dist/fp-macos-arm64  ./cmd/fp
GOOS=windows GOARCH=amd64 go build -o dist/fp-windows-amd64.exe ./cmd/fp
```

## Install target

`install.sh` drops the right binary at `/usr/local/bin/fp`.

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
| `fp uninstall` | — | delegates to `shared/uninstall.sh` |

## `.fpconfig` backup format

Identical binary format to `macos/menu-bar-app/FalconPulsar/ConfigBackup.swift`
and `windows/tray-app/ConfigBackup.cs`. Export on one platform, import on
another.

```
[0..3]   Magic "FPCF"
[4]      Format version = 1
[5..20]  PBKDF2 salt (16 bytes)
[21..32] AES-GCM nonce (12 bytes)
[33..]   AES-256-GCM ciphertext of the zip payload
[tail 16 bytes] GCM auth tag
```

Key = `PBKDF2-HMAC-SHA256("<admin_user>:<admin_password>", salt, 100_000, 32)`.

## Admin-only operations

Export and Import require admin credentials. The binary calls
`POST /api/v1/auth/login` and then `GET /api/v1/auth/me` to verify the user
has the `admin` role before proceeding. Non-admins get:

    Error: only administrator accounts can perform this operation.
