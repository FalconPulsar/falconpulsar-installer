# FalconPulsar Installer — Architecture

This document is the deep reference for contributors working on the installer.
It explains **how** each installer works internally, **where** to go to change
specific behaviour, **which** environment variables flow through the system,
and **why** some of the code looks the way it does (the gotchas section is
based on real incidents — ignore it at your peril).

If you just want to use the installer, read the [README](README.md).
If you want to make a contribution, also read [CONTRIBUTING.md](CONTRIBUTING.md).

## Table of contents

- [The three-installer model](#the-three-installer-model)
  - [Two install models (Linux + Windows)](#two-install-models-linux--windows)
  - [Supporting components shipped alongside the bash installers](#supporting-components-shipped-alongside-the-bash-installers)
- [Linux installer](#linux-installer)
- [macOS installer](#macos-installer)
- [Windows installer](#windows-installer)
- [Configuration backup (`.fpconfig`)](#configuration-backup-fpconfig)
- [Shared libraries](#shared-libraries)
- [Environment variables reference](#environment-variables-reference)
- [CI pipeline](#ci-pipeline)
- [Gotchas and non-obvious behaviour](#gotchas-and-non-obvious-behaviour)
- [Debugging tips](#debugging-tips)

---

## The three-installer model

FalconPulsar ships three installers, but **Linux is the canonical one**. macOS
is a bash variant that diverges only where the platform forces it. Windows is
an orchestration wrapper around the Linux installer running inside WSL2.

The rules that make this work:

1. **`shared/compose.yml` is the one compose file.** All three installers
   copy it verbatim — never modify it per-platform.
2. **`shared/lib/*.sh` is sourced by Linux and macOS install/uninstall
   scripts.** If you add logic to one and not the other, they drift. Put
   it in `shared/lib/`.
3. **Windows does not implement install logic.** `installer.iss` and the
   PowerShell helpers only set up the environment (WSL2 + Ubuntu), then
   hand off to `linux/install.sh` running inside WSL2. A Linux bug is
   also a Windows bug, and a Linux fix is also a Windows fix.

### Two install models (Linux + Windows)

The bash installer operates in one of two modes, selected automatically
based on `is_wsl` detection:

| Model | When it runs | Owner of the stack | Stack directory |
|---|---|---|---|
| **service-user** | Native Linux (`sudo bash install.sh`) | Dedicated `falconpulsar` system user created by `useradd` | `/home/falconpulsar/` |
| **per-user** | WSL (under the Windows installer) | The WSL default user (the human) | `/home/<user>/falconpulsar/` |

macOS always runs as the current user under `~/falconpulsar/`. There is no
`falconpulsar` system user on macOS.

The per-user model exists because WSL has a single-user mental model — the
human running the distro. Creating a separate service user produced real
bugs (permission denied on `.env`, `must run as root` on uninstall, `fp`
not found for the user) and no benefit, so WSL now installs under the
invoking human.

### Supporting components shipped alongside the bash installers

- **`console/`** — the `fp` CLI (Go). A TUI + subcommand interface for
  stack lifecycle (`fp status`, `fp start`, `fp update`, `fp uninstall`),
  shipped by every installer.
- **`windows/fp-wrapper/`** — a tiny Go shim that becomes `fp.exe` on
  Windows. Reads a `%TEMP%\falconpulsar-home.txt` sentinel and execs the
  real Linux `fp` inside WSL.
- **`windows/tray-app/`** — a C# / .NET 8 Windows system tray app that
  surfaces stack status, Start/Stop/Restart, uninstall.
- **`macos/installer-app/`** — a SwiftUI GUI installer (ships inside the
  signed `.dmg`); it invokes `macos/install.sh` under the hood.
- **`macos/menu-bar-app/`** — an AppKit menu-bar manager equivalent to
  the Windows tray.
- **`linux/bootstrap.sh`** — a small curl-able dispatcher served at
  `get.falconpulsar.com/linux`. Downloads both the bundled install and
  uninstall scripts and execs whichever subcommand the user asked for.

All of these consume the bash installers; none of them reimplement the
install logic.

## Linux installer

`linux/install.sh` is the reference implementation. Every concept in the
product stack — user creation, Docker install, credential bootstrap, compose
file generation, healthchecks, systemd unit registration — lives here.

### Function call order (top-level)

From `linux/install.sh` main block:

1. **Install-model resolution.** `is_wsl` (from `common.sh`) selects
   service-user or per-user mode. In per-user mode, `FP_USER` comes from
   `FP_INVOKING_USER` (passed by the Windows PowerShell orchestrator)
   or `SUDO_USER`, and `FP_HOME` is derived as `/home/<user>/falconpulsar`.
2. `require_root` — both modes need root for docker install / user
   creation / writing `/etc/profile.d/`.
3. `prompt_legal_acknowledgement` — Terms / Privacy / AUP / Security
   (skippable with `FP_LEGAL_ACCEPTED=1`).
4. **Pre-flight checks** — `check_supported_os`, `check_arch`,
   `check_kernel`, `check_ram`, `check_disk`, `check_ports`.
5. **Docker** — `check_docker_installed` + `check_compose_v2`; if
   missing, `install_docker_linux` via `curl https://get.docker.com | sh`.
   Then `check_docker_daemon`.
6. **Existing-install detection** — `fp_detect_existing_install` +
   `fp_prompt_existing_action`. If a prior install is found (on either
   the current `$FP_HOME` or the legacy `/home/falconpulsar`), the
   user chooses Upgrade / Reinstall / Fresh. The Windows wizard makes
   this choice visually; the bash path is interactive.
7. **Admin auth gate for upgrade/reinstall** — if overwriting a running
   stack, require the existing admin password via `auth.sh`
   (`fp_authenticate_admin`).
8. `fp_apply_existing_action` — performs the pre-install mutation for
   the chosen action (stop containers on reinstall; wipe everything on
   fresh; no-op on upgrade).
9. `fp_try_upgrade_fastpath` — when action is "upgrade" and
   `${FP_HOME}/compose.yml` is intact, skip the full reinstall flow:
   re-verify registry access, re-copy the bundled `compose.yml` +
   `nginx.conf` (product-managed files), provision `gateway.yaml` and
   the gateway secrets when missing (existing `FP_API_KEY` /
   `FP_GATEWAY_SECRET` / `FP_BRIDGE_TOKEN` always carried forward,
   never regenerated), scrub any legacy `FP_AI_GATEWAY_ENABLED=false`
   to `true`, `docker compose pull && docker compose up -d`, hard-gate
   the AI Gateway `/health` endpoint, and exit.
10. `fp_registry_ensure_access` — registry probe + interactive login if
    needed (see `registry_auth.sh`).
11. **User + home directory** — service-user mode: `useradd --system`;
    per-user mode: validate the user already exists. Then
    `add_user_to_docker_group`, set ownership, create `$FP_HOME/data`
    and `$FP_HOME/.docker`.
12. `prompt_admin_credentials` → `FP_ADMIN_USER` / `FP_ADMIN_PASS`
    (generated or prompted; never persisted to disk).
13. **Stack files** — write `compose.yml`, `nginx.conf`, `.env`, and
    `gateway.yaml` into `$FP_HOME`. Mode `.env` = `0640`, owner
    `$FP_USER:docker` (readable by any docker-group user; writable by
    the owner).
14. `fp_compose_pull_with_retry` — 3 retries with backoff, runs as
    `$FP_USER` via `sg docker`.
15. **Start core** — `docker compose up -d core` with `FP_ADMIN_PASS`
    injected only into this one process's env (never written to `.env`).
    Wait for the `core` healthcheck.
16. `fp_bootstrap_gateway_token` — logs in with the admin password,
    creates a service token, appends `FP_API_KEY=<token>` to `.env`
    preserving file mode.
17. **Start the rest** — `docker compose up -d`, then
    `fp_wait_for_gateway_ready` as a hard gate on the AI Gateway
    `/health` endpoint (failure points at the container logs).
18. `fp_install_cli` — install `fp` to `$FP_HOME/bin/fp`; chmod 0755.
19. **PATH integration** — `fp_offer_path_append` to the invoking
    human's shell rc, plus a system-wide `/etc/profile.d/falconpulsar.sh`
    snippet so every shell on the box picks up `fp`.
20. **Reconciliation** — copy `uninstall.sh` + `auth.sh` into `$FP_HOME`
    so `fp uninstall` can run standalone. Re-assert ownership on `.env`
    and `bin/` (belt-and-suspenders against silent no-op chown).
21. Systemd unit registration (service-user mode only, `--mode systemd`).
    Skipped on WSL — WSL doesn't run user-level systemd by default.
22. Post-install health check + banner with Web UI / REST / WebSocket URLs.

### Where things live in `linux/install.sh`

| To change… | Look at |
|---|---|
| Supported distros | `shared/lib/checks.sh` — `check_supported_os` |
| Minimum RAM / disk | `shared/lib/checks.sh` — `check_ram`, `check_disk` |
| Ports checked | `shared/lib/checks.sh` — `FP_DEFAULT_PORTS` constant |
| Service-user creation | `linux/install.sh` — step 11 (`useradd --system`) |
| Per-user / WSL detection | `shared/lib/common.sh` — `is_wsl` |
| Existing-install detection | `shared/lib/existing.sh` — `fp_detect_existing_install`, `fp_prompt_existing_action` |
| Admin authentication | `shared/lib/auth.sh` — `fp_authenticate_admin`, `fp_verify_admin_credentials` |
| Admin credential prompting | `shared/lib/prompts.sh` — `prompt_admin_credentials` |
| Compose + env file generation | `linux/install.sh` — inline heredocs in step 13 |
| API key bootstrap | `shared/lib/bootstrap.sh` — `fp_bootstrap_gateway_token` |
| fp CLI install | `shared/lib/fpcli.sh` — `fp_install_cli` |
| PATH append to user shell rc | `shared/lib/fpcli.sh` — `fp_offer_path_append` |
| systemd unit template | `linux/systemd/falconpulsar.service.template` |

## macOS installer

macOS ships two entry points that end up running the same bash installer:

1. **`macos/installer-app/`** — a SwiftUI GUI installer, distributed in a
   signed `.dmg` (`FalconPulsar-Setup.dmg`). The user drags the `.app`
   to `/Applications` and runs it. `InstallRunner.swift` shells out to
   `macos/install.sh` bundled inside the `.app` for the actual install
   work — the GUI is chrome over the bash engine.
2. **`macos/install.sh`** — the headless bash installer. Runnable
   directly (e.g. `curl -fsSL .../macos | bash`) for CI / automation.

### Divergences from Linux (in `macos/install.sh`)

| Concern | Linux | macOS |
|---|---|---|
| Privilege | `require_root` | `require_not_root` (runs as current user) |
| Docker | Installed via `get.docker.com` | **Must be pre-installed** (Docker Desktop / Colima / OrbStack / Rancher Desktop) |
| Dedicated user | Creates `falconpulsar` system user (service-user mode) | Uses the current user's home directory |
| Stack directory | `/home/falconpulsar/` or `/home/<user>/falconpulsar` | `~/falconpulsar/` |
| RAM minimum | 4 GB | 8 GB (Docker Desktop overhead) |
| Lifecycle | Optional systemd user unit | `restart: unless-stopped` (container engine handles it) |
| User / group IDs | `FP_UID=$(id -u falconpulsar)` (service-user) | `FP_UID=$(id -u)` (current user) |

### macOS-specific functions

- `require_not_root` — refuses to run under sudo (bind-mount ownership would break)
- `detect_mac_runtime` — probes Docker Desktop, Colima, OrbStack, Rancher Desktop and reports which is installed / running

### macOS menu-bar app (`macos/menu-bar-app/`)

An AppKit application installed to `/Applications/FalconPulsar Menu Bar.app`
by the installer. Shows stack status in the system menu bar, surfaces
Start/Stop/Restart, config backup, and uninstall. Authenticates
admin operations against Core's REST API using the same admin password
the install captured. Mirrors the Windows tray app feature-for-feature.

### macOS package builders

- `macos/build-dmg.sh` — assembles the signed `.dmg`. Pulls the
  installer `.app` from `macos/installer-app/` + the menu-bar `.app`
  from `macos/menu-bar-app/` + the `fp` binary from `console/dist/`,
  and produces a `FalconPulsar-Setup.dmg` suitable for distribution.
- `macos/pkg/build-pkg.sh` — builds a `.pkg` as an alternative
  distribution format. Uses `macos/pkg/resources/` for the welcome /
  license / conclusion panes.

Both packagers run on macOS only (require `codesign`, `pkgbuild`,
`productbuild`, `hdiutil`). CI runs them on a `macos-latest` runner
via `build-macos.yml`.

No macOS-only prompts in the bash flow; the interactive CLI is
identical to Linux. The GUI (SwiftUI) has its own wizard sequence.

## Windows installer

The Windows installer is the non-obvious one. Read this section before
touching anything under `windows/`.

### The handoff model

Windows is a GUI wizard (Inno Setup) that sets up WSL2 + Ubuntu, then runs
the bash Linux installer inside the WSL distro. There is **no Windows-native
install logic** — every step that actually deploys FalconPulsar is the same
code that runs on a bare-metal Linux box.

The chain is:

```
FalconPulsar-Setup.exe
  └── installer.iss (Inno Setup + Pascal Script)
        │
        ├── InitializeSetup:
        │     └── powershell.exe → helpers/05-detect-environment.ps1
        │     └── powershell.exe → helpers/06-detect-existing-install.ps1
        │           (populate the Existing-Install wizard page if applicable)
        │
        ├── Wizard: Welcome → Legal → Credentials → Registry →
        │          Existing-Install (conditional) → Install-Location → Ready
        │
        └── CurStepChanged(ssPostInstall)
              ├── powershell.exe → helpers/00-check-prereqs.ps1
              ├── powershell.exe → helpers/10-enable-wsl.ps1 (conditional)
              ├── powershell.exe → helpers/20-install-distro.ps1 (conditional)
              ├── powershell.exe → helpers/25-test-registry.ps1
              ├── powershell.exe → helpers/30-configure-distro.ps1
              ├── powershell.exe → helpers/40-run-fp-installer.ps1
              │     ├── resolves the WSL default user (whoami inside distro)
              │     ├── writes %TEMP%\falconpulsar-home.txt sentinel
              │     │   (read by fp.exe, tray, and uninstall helpers)
              │     ├── stages linux/ + shared/ into /opt/falconpulsar-installer
              │     └── wsl.exe -d <distro> -u root -- bash
              │           └── /opt/falconpulsar-installer/linux/install.sh
              │                 --user '<wsl-default-user>' --mode docker --yes
              │                 (per-user mode: stack owned by the human user)
              ├── powershell.exe → helpers/45-verify-health.ps1
              └── powershell.exe → helpers/50-register-shortcuts.ps1
```

Post-install, the user interacts with the stack through:

- **`fp.exe`** (`windows/fp-wrapper/`) — a Go shim installed at
  `%LOCALAPPDATA%\Microsoft\WindowsApps\fp.exe` (always on user PATH
  without explicit Path additions). Reads the home sentinel, execs the
  real Linux `fp` binary inside WSL via `wsl.exe`.
- **`FalconPulsarTray.exe`** (`windows/tray-app/`) — a C# / .NET 8
  system tray app installed to `Program Files\FalconPulsar\`. Polls
  container status, surfaces Start/Stop/Restart, admin-authenticated
  uninstall.
- **Start Menu shortcuts** — created by `50-register-shortcuts.ps1`,
  launch `wsl.exe` bash commands against the stack directory.

### Wizard pages (`installer.iss`)

1. **Welcome** — standard Inno Setup welcome with custom subtext.
2. **Legal acknowledgement** — custom Pascal page: four clickable links
   (Terms, Privacy, AUP, Security), checkbox required before Next.
3. **Admin credentials** — custom `CreateInputQueryPage`: username (default
   `admin`) + password + confirm. Minimum 10 characters.
4. **Container Registry** — custom page: registry URL (default
   `falconpulsar`), optional username / password, and a **Test Connection**
   button that runs `25-test-registry.ps1` inside WSL before allowing Next.
5. **Existing Install** (conditional) — custom page shown only when
   `06-detect-existing-install.ps1` reports a prior stack. Radio group:
   Upgrade in place / Reinstall (keep data) / Fresh install. Dynamic
   layout (`LayoutExistingPage`) adjusts control positions based on
   what the detection found (containers count, stack size, etc.).
6. **Installation location** — standard page, defaults to
   `%PROGRAMFILES%\FalconPulsar`.
7. **Ready + Finish** — postinstall checkboxes to launch the tray and
   open `http://localhost:8080`.

### Upgrade detection

`InitializeSetup` in the `[Code]` section checks the Inno Setup uninstall
registry key:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{AppId}_is1
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{AppId}_is1
```

If present, `IsUpgrade := True` and `ShouldSkipPage` skips the legal and
credentials pages (the admin user already exists in the database). Upgrade
mode passes placeholder credentials to the PowerShell helpers, which detect
the existing `compose.yml` and just run `docker compose pull && docker compose up -d`.

Why the registry key and not `FileExists`? Because leftover files from a
partially failed previous install trigger false positives. The registry key
only gets written after a **completed** install.

### PowerShell helpers (execution order)

Called in sequence by `CurStepChanged(ssPostInstall)` via the `RunHelper`
procedure. Every helper sources `lib.ps1` first for shared logging and WSL
helpers.

| Helper | Purpose |
|---|---|
| `00-check-prereqs.ps1` | Administrator check, Windows build ≥ 19045, x64 only, VT-x / AMD-V enabled. |
| `05-detect-environment.ps1` | Run in `InitializeSetup`. Probes WSL state (disabled / needs-install / working), enumerates installed WSL distros, detects Docker Desktop, and reports disk free. Populates the wizard's detection summary. |
| `06-detect-existing-install.ps1` | Run in `InitializeSetup`. Probes for a prior FalconPulsar install on both the per-user stack dir and the legacy `/home/falconpulsar` service-user dir. Counts containers / images / volumes / networks. Writes `%TEMP%\falconpulsar-existing.txt` for the Pascal code to read into the Existing-Install wizard page. |
| `10-enable-wsl.ps1` | Enable `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform` Windows features, `wsl --update` the kernel, exit code 2 if reboot required. |
| `20-install-distro.ps1` | `wsl --install -d Ubuntu-24.04 --no-launch` if distro not registered; write distro name to `%TEMP%\falconpulsar-distro.txt` (sentinel used by later helpers). |
| `25-test-registry.ps1` | Run by the wizard's Registry page Test Connection button. `docker manifest inspect` against `$FP_REGISTRY/core:$FP_VERSION` inside WSL; classifies the result as OK / auth-needed / other-error and reports back to the Pascal code for display. |
| `30-configure-distro.ps1` | Write `systemd=true` to `/etc/wsl.conf` inside the distro, `wsl --terminate` to pick up the change. |
| `40-run-fp-installer.ps1` | The core handoff. Resolves the WSL default user (`whoami` inside the distro, falling back to UID 1000), writes `%TEMP%\falconpulsar-home.txt` + `falconpulsar-user.txt` sentinels, stages `linux/` + `shared/` into `/opt/falconpulsar-installer` inside WSL (avoids 9p mount issues). On `fresh`: wipes any prior WSL state (containers, images, volumes, legacy `/home/falconpulsar`, stale systemd linger). Runs `bash install.sh --user '<wsl-user>' --mode docker --yes` with credentials passed via a temp env file (never argv). Installs the Linux `fp` binary at `$WslHome/bin/fp`. Pre-flight port-conflict detection on the Windows side before handoff. |
| `45-verify-health.ps1` | Post-install: probe that the expected containers are running and the REST API responds. Reports the stack URL and, on failure, the relevant log locations. |
| `50-register-shortcuts.ps1` | Create Start Menu shortcuts: Open Web UI, Start/Stop/Restart/Status/Tail Logs (`wsl -d <distro> -- docker compose ...`), Open Stack Folder (`\\wsl.localhost\<distro>\home\<user>\falconpulsar`), Open Install Log. |
| `uninstall.ps1` | Called by Inno Setup's `CurUninstallStepChanged` when the user runs the Windows uninstaller (or `fp uninstall` on WSL, which hands off to `unins000.exe`). Prompts for Yes/No/Cancel (purge / keep-data / abort), gates on admin authentication (`Assert-AdminAuth`). Stops and removes the `falconpulsar-*` containers + images + (on purge) volumes, removes the WSL stack dir(s), removes Start Menu shortcuts, cleans `%USERPROFILE%\falconpulsar`, `%LOCALAPPDATA%\falconpulsar`, `%LOCALAPPDATA%\Microsoft\WindowsApps\fp.exe`, the HKCU Run auto-start entry, and any stale HKCU `Environment\Path` segments containing `\falconpulsar`. Does **not** unregister the WSL distro (may host other things). Opens `%TEMP%\falconpulsar-install.log` in Notepad when done. |

### lib.ps1 (shared helpers)

- `Write-Step`, `Write-Info`, `Write-Warn`, `Write-Err`, `Stop-WithError` —
  coloured logging that **appends** to `%TEMP%\falconpulsar-install.log`
  (never overwrites; orchestrator truncates at start of run)
- `Test-Wsl2Enabled`, `Test-WslWorking` — Windows feature probes
- `Get-WslDistroVersion` — returns 1 or 2 for a named distro
- `Invoke-WslBash` — **the single correct way** to run bash inside WSL from
  PowerShell. Strips `\r` characters before passing the script (see gotcha
  #3 below).
- `ConvertTo-WslPath` — `C:\Program Files\FalconPulsar` → `/mnt/c/Program Files/FalconPulsar`

### Credentials handling

The admin password is **never** passed on the command line. The flow:

1. Inno Setup collects the password on the Credentials page
2. `installer.iss` passes it as `-AdminPass "..."` to `40-run-fp-installer.ps1`
3. The PowerShell helper writes it to a temporary env file inside WSL:
   ```bash
   ENVFILE=$(mktemp /root/fp-install.env.XXXXXX)
   trap 'rm -f "$ENVFILE"' EXIT
   cat > "$ENVFILE" <<__FP_ENV_EOF__
   export FP_ADMIN_USER='...'
   export FP_ADMIN_PASS='...'
   __FP_ENV_EOF__
   . "$ENVFILE"
   rm -f "$ENVFILE"
   bash /opt/falconpulsar-installer/linux/install.sh --mode docker --yes
   ```
4. The file is deleted in the same bash invocation, before `install.sh` runs

This avoids exposing the password via `/proc/<pid>/cmdline`, which is
world-readable to any local user.

## Configuration backup (`.fpconfig`)

FalconPulsar ships three independent implementations of the configuration
backup feature — one per platform — because they each need to integrate
with native UI primitives (NSAlert, Windows.Forms, `tview`/`cobra`). All
three produce + consume the same binary file format, so a backup created
on macOS can be restored on Linux and vice versa.

| Platform | Source | UI surface |
|---|---|---|
| macOS | `macos/menu-bar-app/FalconPulsar/ConfigBackup.swift` | Tray → Configuration Backup → Export/Import |
| Windows | `windows/tray-app/ConfigBackup.cs` | Tray → Configuration Backup → Export/Import |
| Linux | `console/internal/configbackup/backup.go` | `fp config export/import` CLI + `fp` TUI (F7/F8) |

The authoritative format spec lives in the Go file; the Swift and C# files
must be kept in sync.

### File format (binary envelope)

```
[0..3]   Magic = "FPCF"
[4]      Format version (writes: 2; readers accept: 1..2)
[5..20]  PBKDF2 salt (16 bytes)
[21..32] AES-GCM nonce/IV (12 bytes)
[33..]   AES-256-GCM ciphertext of the zip payload
[tail 16 bytes] GCM auth tag
```

Key derivation: `PBKDF2-HMAC-SHA256("<admin_user>:<admin_password>",
salt, 100_000 iterations, 32-byte output)`.

### Payload (zip)

```
manifest.json                  format_version + fp_version + host + timestamp
files/compose.yml              docker compose for the stack
files/.env                     env vars (may contain secrets — encrypted)
files/gateway.yaml             AI Gateway config seed
api/roles.json                 GET /api/v1/roles
api/users.json                 GET /api/v1/users
api/asset-types.json           GET /api/v1/asset-types          (new in v2)
api/assets.json                GET /api/v1/assets
api/datasources.json           GET /api/v1/datasources
api/series.json                GET /api/v1/series               (new in v2)
api/mappings.json              GET /api/v1/mappings
api/relationships.json         GET /api/v1/relationships        (new in v2)
api/annotations.json           GET /api/v1/annotations          (new in v2)
```

### Import behaviour

Sections are applied in **dependency order** so foreign keys resolve:

```
roles → asset-types → users → datasources → assets → series →
mappings → relationships → annotations
```

For each item the client **strips server-generated fields** (`id`,
`created_at`, `updated_at`, `point_count`, `disk_bytes`,
`first/last_timestamp`, `last_value`/`last_value_ts`) before POSTing.
This forces the target server to mint fresh IDs using the **natural
keys** (`name`, `path`, `username`, etc.). Otherwise the source
instance's UUIDs would either collide or cause FK lookup failures.

Conflicts (HTTP 409) are counted as **skipped** — they're treated as
"already present, no action needed", not as errors. Other HTTP failures
are counted as **errors** and the first 5 messages per section are
surfaced in the result UI.

### Phase B — server-side `/api/v1/admin/backup` (planned)

The three implementations currently duplicate ~250 lines of harvest +
parse + apply logic each. A future change will move the logic into
Core's REST API:

```
POST /api/v1/admin/backup/export
  → returns the raw zip+manifest+entity-JSON payload as a binary stream
  → client wraps with AES-GCM and writes to disk

POST /api/v1/admin/backup/import?dry_run=1&on_conflict=skip|overwrite|merge
  → accepts the decrypted payload
  → applies atomically with proper transaction boundaries
  → returns a structured summary

GET  /api/v1/admin/backup/manifest
  → preview what an import would do without applying
```

Once these land, the macOS Swift / Windows C# / Linux Go implementations
all become thin wrappers around the three endpoints, eliminating the
~250 LOC × 3 duplication. The on-disk `.fpconfig` format stays unchanged
so backups created today are still readable by future versions.

The Web UI (Config Hub) can then add a "Backup" page that reuses the
same endpoints — no need for the UI to bundle the Go console or shell
out to it.

This was deliberately scoped out of the v2 work because the immediate
data-correctness gap (missing entity types, silent import failures) was
more pressing. Once the server endpoint lands, the bundled `.fpconfig`
format gracefully bumps to v3 with the same v1/v2 backward-compat story.

## Shared libraries

`shared/lib/` is the heart of the installer. Eight files, each
source-guarded so they can be sourced from anywhere:
`common.sh`, `checks.sh`, `prompts.sh`, `bootstrap.sh`, `auth.sh`,
`registry_auth.sh`, `fpcli.sh`, `existing.sh`.

### `common.sh` — logging, errors, privilege, utilities

| Function | Purpose |
|---|---|
| `log_info` / `warn` / `error` / `success` / `step` / `debug` | Coloured stderr logging (respects `NO_COLOR` and TTY detection) |
| `die` | Log error + `exit 1` |
| `on_error` | `ERR` trap handler with call stack |
| `require_cmd` | Verify a command exists in `PATH` |
| `is_root` / `require_root` / `require_not_root` | Privilege checks |
| `confirm` | Yes/no prompt (auto-yes if `FP_ASSUME_YES=1`) |
| `run_as_user` | Re-exec a command as another user (via `sudo` or `su`) |
| `random_password` | 24-char URL-safe base64 password |
| `detect_os` | Returns `linux`, `macos`, `wsl`, or `unknown` |

### `checks.sh` — OS, hardware, Docker probes

| Function | Purpose |
|---|---|
| `detect_distro` | Read `/etc/os-release`, export `FP_DISTRO_ID`/`VERSION`/`LIKE` |
| `version_ge` | Compare dotted version strings |
| `check_supported_os` | Whitelist: Ubuntu 22.04+, Debian 12+, RHEL 9+, Fedora 41+, openSUSE 15.6+, macOS 14+ |
| `check_arch` | `x86_64` or `arm64` |
| `check_kernel` | ≥ 5.15 (warning only) |
| `check_systemd` | systemd ≥ 245 running (Linux `--mode systemd` only) |
| `check_ram` | 4 GB (Linux) or 8 GB (macOS / WSL) |
| `check_disk` | 10 GB free |
| `port_in_use` / `port_holder` | Test and identify port holders (`ss` / `lsof` / `netstat` fallback) |
| `check_ports` | Test `FP_DEFAULT_PORTS` = `7433 7434 7435 7436 8080` |
| `check_docker_installed` / `check_compose_v2` / `check_docker_daemon` | Docker / Compose probes |
| `check_dockerhub_login` | **Deprecated** — superseded by `fp_registry_ensure_access` in `registry_auth.sh`, which probes pull access instead of just checking for creds |
| `install_docker_linux` | `curl https://get.docker.com \| sh` |
| `add_user_to_docker_group` | `usermod -aG docker` |
| `check_docker_as_user` | Test if `falconpulsar` can reach the Docker daemon |

### `prompts.sh` — interactive user input

| Function | Purpose |
|---|---|
| `prompt_legal_acknowledgement` | Show four document links, require confirmation (auto-accept via `FP_LEGAL_ACCEPTED=1`) |
| `prompt_string` | Read with default value (auto-use default if `FP_ASSUME_YES=1`) |
| `prompt_path` | Like `prompt_string` but expands `~` and checks parent directory exists |
| `prompt_password` | Read twice with no echo, minimum 10 characters |
| `prompt_admin_credentials` | Fill `FP_ADMIN_USER` (default `admin`) and `FP_ADMIN_PASS` (generate or prompt) |

### `registry_auth.sh` — container registry probe, prompt, login

Handles the "can we actually pull FalconPulsar images from the configured
registry?" question. Works against any OCI-compliant registry (Docker Hub,
GHCR, Quay, Harbor, GitLab, AWS ECR, GCR, Azure ACR, self-hosted).

| Function | Purpose |
|---|---|
| `fp_registry_hostname` | Extract hostname for `docker login` — returns `docker.io` for bare namespaces like `falconpulsar`, or `ghcr.io` from `ghcr.io/falconpulsar` |
| `fp_registry_image_path` | Compose `$reg/$image:$tag` into a full reference |
| `fp_registry_probe` | `docker manifest inspect` against `$FP_REGISTRY/core:$FP_VERSION`. Returns 0 (ok), 1 (auth needed), 2 (other error). Classifies the error string — never prompts. |
| `fp_registry_login` | `docker login --password-stdin` wrapping with error detection (unauthorized → 1, other → 2). Password never hits argv. |
| `fp_registry_prompt_credentials` | Interactive username + password entry (password echo disabled via `stty -echo`) |
| `fp_registry_prompt_registry` | Ask for an alternative registry URL and reset credentials |
| `fp_registry_prompt_menu` | The "have creds / different registry / cancel" 3-option menu shown when probe returns auth-needed |
| `fp_registry_ensure_access` | **Top-level orchestrator.** Called from `linux/install.sh` and `macos/install.sh`. Probes → optional login → re-probe → retry (up to `FP_REGISTRY_MAX_RETRIES`, default 3). Honours `FP_ASSUME_YES` for non-interactive mode. |

### Credentials for cloud-native registries

All three cloud providers (AWS ECR, Google Artifact Registry, Azure ACR)
support standard username/password auth via `docker login`, which is all
the installer needs. You just have to generate the right token ahead of
time.

| Registry | Username | Password / token | How to get it |
|---|---|---|---|
| **Docker Hub** | Docker Hub username | Personal Access Token (recommended) or password | [hub.docker.com/settings/security](https://hub.docker.com/settings/security) → New Access Token |
| **GHCR** (GitHub Container Registry) | GitHub username | GitHub PAT with `read:packages` scope | [github.com/settings/tokens](https://github.com/settings/tokens) → Generate new token (classic) |
| **AWS ECR (private)** | `AWS` | Output of `aws ecr get-login-password --region <region>` | Long-lived: create an IAM user with `AmazonEC2ContainerRegistryReadOnly`, use `access-key:secret-key` as user/pass via STS token |
| **AWS ECR Public** | `AWS` | Output of `aws ecr-public get-login-password --region us-east-1` | Same as above |
| **GCR / Google Artifact Registry** | `_json_key` | Contents of a service account JSON key file | GCP Console → IAM → Service Accounts → create key (JSON). The entire JSON file content is the "password". |
| **Azure ACR** | Service Principal appId | Service Principal password | `az ad sp create-for-rbac --scopes <acr-scope> --role acrpull` |
| **Quay / Harbor / GitLab / self-hosted** | As configured in the registry | Personal access token or password | Registry-specific |

Feed the values into the installer via env vars (`FP_REGISTRY_USER` +
`FP_REGISTRY_PASS`) or the Windows wizard's Container Registry page. The
installer does the `docker login --password-stdin` for you.

### `bootstrap.sh` — first-run API bootstrap

| Function | Purpose |
|---|---|
| `fp_wait_for_api_ready` | Loop on `curl /api/v1/health` until 200 or 180 s timeout |
| `fp_wait_for_gateway_ready` | Loop on the AI Gateway `/health` endpoint (`127.0.0.1:${FP_GATEWAY_PORT}`, default 7436) until 200 or 180 s timeout. Returns non-zero instead of dying so the caller can point at the container logs. Used by both installers as a hard gate after `docker compose up -d`. |
| `_fp_json_str` | Tiny grep-based JSON field extractor (not a real parser — avoid complex payloads) |
| `fp_bootstrap_gateway_token` | POST `/api/v1/auth/login` → JWT → POST `/api/v1/tokens` → service token for AI Gateway → append `FP_API_KEY=<token>` to `.env`. **Preserves the existing file mode** (stat + chmod) so the 0640 / 0600 chosen by the installer survives — do not hard-code a mode here. |
| `fp_wipe_gateway_seed_defaults` | Delete the LLM providers/models the gateway image self-seeds on first boot, so a clean install starts with an empty AI configuration. Runs after the health gate; non-fatal on failure. |

### `auth.sh` — admin-password authentication gate

Used by install.sh (for upgrade / reinstall authorization) and
uninstall.sh (to require admin creds before any destructive action).

| Function | Purpose |
|---|---|
| `fp_verify_admin_credentials` | Verify a single `<user, password>` pair against `POST /api/v1/auth/login`. Returns 0 (valid), 1 (invalid), 2 (API unreachable). |
| `fp_authenticate_admin` | Interactive: prompt for username + password, verify, retry up to N times (default 3). Used when `FP_ADMIN_PASS` is not already in env. |

The `FP_FORCE=1` env var bypasses this check — intended only for
emergency uninstall when Core is completely broken.

### `fpcli.sh` — fp CLI installation + PATH integration

| Function | Purpose |
|---|---|
| `fp_install_cli` | Install the `fp` binary to `$FP_HOME/bin/fp`; chmod 0755; chown to the stack owner. Looks up the bundled binary at several candidate locations (next to install.sh, next to the bundler's temp dir, `/opt/falconpulsar-installer/console/dist/`). |
| `fp_offer_path_append` | Interactive prompt to append `$FP_HOME/bin` to the invoking human's shell rc (`.bashrc` / `.zshrc`). Auto-accept via `FP_ADD_TO_PATH=1` or `FP_ASSUME_YES=1`. On per-user mode the installer also drops `/etc/profile.d/falconpulsar.sh` so every new shell picks `fp` up without needing the rc edit. |

### `existing.sh` — prior-install detection + action orchestration

| Function | Purpose |
|---|---|
| `fp_detect_existing_install` | Probe the filesystem and Docker for signs of a prior install under `$FP_HOME`: stack dir present, `compose.yml` present, `.env` present, `data/` present (+ size), running containers matching `falconpulsar-*`, images matching `*falconpulsar*`, menu-bar app on macOS. Populates `FP_EXISTING_*` globals. |
| `fp_has_existing_install` | Returns 0 if any of the detection probes found real install artifacts (`compose.yml` / `.env` / containers / images / menu-bar app). An empty stack dir alone does NOT count — `useradd --create-home falconpulsar` creates `/home/falconpulsar` on Linux, which is not an install artifact. |
| `fp_print_existing_inventory` | Pretty-print what the detection found (coloured, sized). Shown before the action prompt. |
| `fp_prompt_existing_action` | Interactive Upgrade / Reinstall / Fresh / Cancel menu. Honours `FP_INSTALL_ACTION` env var (non-interactive). On "Fresh" requires type-to-confirm (`DELETE` uppercase) to guard against accidents. |
| `fp_apply_existing_action` | Execute the pre-install mutation: upgrade = no-op (keep everything); reinstall = `docker compose down` + remove stack files, preserve data; fresh = stop containers, remove images, volumes, `rm -rf "$FP_HOME"`. |
| `fp_try_upgrade_fastpath` | When action is "upgrade" and a valid `compose.yml` is present, skip the full reinstall flow: re-copy the bundled `compose.yml` + `nginx.conf` (product-managed files), copy `gateway.yaml` if missing, carry secrets (`FP_API_KEY` / `FP_GATEWAY_SECRET` / `FP_BRIDGE_TOKEN`) forward in `.env`, `docker compose pull && docker compose up -d`, health-gate the gateway, and exit 0. |

### `shared/compose.yml`

Three services on a single user-defined bridge network `falconpulsar`:

| Service | Image | Ports | Depends on |
|---|---|---|---|
| `core` | `${FP_REGISTRY}/core:${FP_VERSION}` | 7433 / 7434 / 7435 | — |
| `ui` | `falconpulsar/ui:latest` | 8080 | `core` (healthy) |
| `ai-gateway` | `falconpulsar/ai-gateway:latest` | 7436 | `core` (healthy) |

- The `core` service has a `bash /dev/tcp/localhost/7433` healthcheck (5 retries × 15 s interval, 90 s start period)
- The `ai-gateway` service has the same `bash /dev/tcp/localhost/7436` healthcheck shape (the image ships without curl)
- All services use `user: ${FP_UID}:${FP_GID}` for bind-mount ownership
- All services are `restart: unless-stopped`
- Volumes: `${FP_DATA_DIR}:/data` bind-mount for `core` (database)

## Environment variables reference

Every `FP_*` variable the installer reads or writes. User-facing variables are
bold.

| Variable | Default | Read by | Purpose |
|---|---|---|---|
| **`FP_ADMIN_USER`** | `admin` | `prompts.sh`, `compose.yml` | Initial admin username |
| **`FP_ADMIN_PASS`** | generated or prompted | `prompts.sh`, `bootstrap.sh`, `compose.yml` | Initial admin password (first run only, never persisted) |
| **`FP_REGISTRY`** | `falconpulsar` | `registry_auth.sh`, `compose.yml`, `.env` | Container registry prefix (namespace, or hostname/namespace for non-Docker Hub registries). Set to any OCI-compliant registry for mirroring or private distribution. |
| **`FP_VERSION`** | `latest` | `registry_auth.sh`, `compose.yml`, `.env` | Image tag to pull. Pin to a semver (`v0.1.0`) to stop floating. |
| **`FP_REGISTRY_USER`** | unset | `registry_auth.sh` | Optional username for registry login (honoured in non-interactive mode). |
| **`FP_REGISTRY_PASS`** | unset | `registry_auth.sh` | Optional password / token for registry login. |
| **`FP_REGISTRY_SKIP`** | `0` | `registry_auth.sh` | Set to `1` to bypass the registry probe entirely (air-gapped or pre-pulled images). |
| `FP_API_KEY` | empty until first run | `bootstrap.sh`, `compose.yml` | AI Gateway service token (written to `.env` after bootstrap) |
| `FP_AI_GATEWAY_ENABLED` | `true` (always) | nothing (legacy compat) | Written to `.env` as `true` so pre-mandatory-gateway `fp` / tray binaries that still read the key keep working; upgrades scrub any legacy `false` to `true`. Never read by current code and not user-settable — the AI Gateway is a mandatory service. |
| **`FP_ASSUME_YES`** | `0` | `common.sh`, `prompts.sh`, `checks.sh` | Skip all interactive prompts (CI / unattended mode) |
| **`FP_LEGAL_ACCEPTED`** | `0` | `prompts.sh` | Pre-accept legal documents (set to `1`) |
| **`FP_DEBUG`** | `0` | `common.sh`, both installers | Verbose debug logging (also via `--debug` flag) |
| `FP_HOME` | `/home/falconpulsar` (service-user), `/home/<user>/falconpulsar` (per-user / WSL), `~/falconpulsar` (macOS) | both installers | Stack directory |
| `FP_USER` | `falconpulsar` (service-user) or the WSL default user (per-user) | `linux/install.sh` | Owner of the stack |
| `FP_INSTALL_MODEL` | auto-detected by `is_wsl` | `linux/install.sh`, `linux/uninstall.sh` | `service-user` (native Linux) or `per-user` (WSL). Controls useradd/userdel, root-requirement, PATH integration strategy. |
| `FP_INVOKING_USER` | unset (passed by PowerShell on Windows) | `linux/install.sh` | Name of the human user the Windows orchestrator resolved. When set, install.sh uses this for `FP_USER` instead of `SUDO_USER`. |
| `FP_INSTALL_ACTION` | prompted via `fp_prompt_existing_action` | `linux/install.sh`, `40-run-fp-installer.ps1` | `upgrade` / `reinstall` / `fresh` — pre-decided by the Windows wizard or set for non-interactive installs. |
| `FP_FORCE` | `0` | `linux/uninstall.sh`, `windows/helpers/uninstall.ps1`, `auth.sh` | Skip admin-password authentication (emergency use only — broken Core). |
| `FP_DATA_DIR` | `$FP_HOME/data` | both installers, `compose.yml` | Database bind-mount source |
| `FP_GATEWAY_DATA_DIR` | `$FP_HOME/ai-gateway-data` | both installers, `compose.yml` | AI-gateway data bind-mount (knowledge base, conversations). |
| `FP_UID` / `FP_GID` | `id -u` / `id -g` | both installers, `compose.yml` | Container user (for bind-mount ownership) |
| `FP_REST_PORT` | `7433` | `compose.yml` | REST API port |
| `FP_WS_PORT` | `7434` | `compose.yml` | WebSocket port |
| `FP_PUBSUB_PORT` | `7435` | `compose.yml` | Pub/Sub WebSocket port |
| `FP_GATEWAY_PORT` | `7436` | `compose.yml` | AI Gateway port |
| `FP_UI_PORT` | `8080` | `compose.yml` | Web UI port |
| `FP_LOG_LEVEL` | `info` | `compose.yml` | Log level: `debug` / `info` / `warn` / `error` |
| `FP_INSTALL_MODE` | prompted | `linux/install.sh` | `docker` or `systemd` (Linux only) |
| `FP_BIND` | `0.0.0.0` | `compose.yml` | Core bind address |
| `FP_INIT_CONFIG` | unset | `compose.yml` | Path to `init.json` for schema/asset/datasource bootstrap |
| `FP_DISTRO_ID` / `_VERSION` / `_LIKE` | auto | `checks.sh` | Detected from `/etc/os-release` |
| `FP_MIN_RAM_MB_LINUX` / `_OTHER` | `4096` / `8192` | `checks.sh` | RAM thresholds |
| `FP_MIN_DISK_GB` | `10` | `checks.sh` | Disk threshold |
| `FP_DEFAULT_PORTS` | `7433 7434 7435 7436 8080` | `checks.sh` | Ports tested by `check_ports` |

**LLM provider credentials** (Anthropic, xAI, OpenAI, Ollama, etc.) are NOT
set via env vars or `.env`. They are configured through the Web UI
(Settings > AI Configuration) and persisted in the Core database; the AI
gateway reads them over the REST API at runtime. Keeping secrets out of
`.env` means (a) no plaintext on disk outside the DB, (b) rotation through
the UI only, (c) no divergence between `.env` and DB state.

Also honoured: `NO_COLOR` (disables ANSI colours), `DOCKER_CONFIG` (alternate
Docker config path).

## CI pipeline

All workflows live in `.github/workflows/`.

| Workflow | Trigger | Purpose | Required secrets |
|---|---|---|---|
| `lint.yml` | push to `main`, PR | `shellcheck` on all bash scripts (`install.sh`, `uninstall.sh`, `bootstrap.sh`, `shared/lib/*.sh`); validate `compose.yml` | — |
| `test-linux.yml` | push to `main`, PR | Smoke-test `linux/install.sh --mode docker` inside an Ubuntu 24.04 container | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (private image access) |
| `build-fp.yml` | push to `main` + `v*` tags, PR | Cross-compile the `fp` CLI for linux-amd64, linux-arm64, macos-arm64, macos-amd64, windows-amd64. Uploads artifacts. | — |
| `build-macos.yml` | push to `main` + `v*` tags, PR | Build the signed `.dmg` on a `macos-latest` runner (`build-dmg.sh`). | (Apple signing secrets when enabled; see macOS signing section) |
| `build-windows.yml` | push to `main` + `v*` tags, PR | Compile `installer.iss` to `.exe` on `windows-latest`; builds both the fp-wrapper and Linux `fp` binaries for bundling (does **not** run the installer — see gotcha #5) | — |
| `release.yml` | `v*` tags only | Bundle Linux install + uninstall + bootstrap + macOS install via `bundle.sh`; re-run the DMG + Windows `.exe` builds; create a GitHub Release with versioned + unversioned assets | `GITHUB_TOKEN` (automatic) |
| `cleanup-runs.yml` | `workflow_run` from the above | Periodic housekeeping to trim old workflow runs so the Actions history doesn't balloon. | — |

Docs-only changes (`**/*.md`, `LICENSE`, `.gitignore`, `.editorconfig`) are
ignored by all of the above via `paths-ignore`.

## Gotchas and non-obvious behaviour

This is the section that will save future contributors hours. Every item
below is based on a real incident we debugged.

### 1. PowerShell 5.1 reads `.ps1` files as Windows-1252, not UTF-8

**Symptom:** The installer dies with `Missing closing '}'` or `string missing
terminator` errors on a file that *looks* syntactically correct in a UTF-8
editor.

**Cause:** Windows PowerShell 5.1 (which ships with all supported Windows
versions) reads scripts in the system ANSI codepage, not UTF-8. Non-ASCII
characters — em dashes (—), en dashes (–), arrows (→), box-drawing (═), curly
quotes (" ') — get misinterpreted and break the parser.

**Rule:** **All `.ps1` files must be pure 7-bit ASCII.** Use `--` instead of
em dashes, `->` instead of arrows, `=` instead of `═`. Check before committing:

```bash
perl -ne 'print "$ARGV:$.: $_" if /[^\x00-\x7F]/' windows/helpers/*.ps1
```

### 2. `ErrorActionPreference=Stop` kills scripts on `wsl.exe` non-zero exit

**Symptom:** `10-enable-wsl.ps1` or `20-install-distro.ps1` aborts with no
useful error output. Inno Setup reports the helper failed but doesn't say
why.

**Cause:** `lib.ps1` sets `$ErrorActionPreference = 'Stop'`, which is normally
what you want — any PowerShell cmdlet error stops the script. But native
executables (`wsl.exe`, `wsl --update`) can return non-zero exit codes
that PowerShell propagates as terminating errors.

**Rule:** Wrap every `wsl.exe` call that can legitimately fail (`--status`,
`--update`, `--list`) in a `try`/`catch` block, and check `$LASTEXITCODE`
explicitly. The helpers already follow this — when adding new ones, copy
the pattern from `10-enable-wsl.ps1`.

### 3. PowerShell heredocs produce CRLF; bash inside WSL chokes on `\r`

**Symptom:** Weird errors like `cp: cannot create directory
'/opt/falconpulsar-installer/'$'\r'` or `bash: /opt/...': No such file or
directory` when a path *looks* correct.

**Cause:** PowerShell heredocs (`@'...'@`) emit Windows line endings
(`\r\n`). When that string is passed to `wsl.exe -- bash -c "..."`, bash
treats `\r` as a literal character, corrupting paths and commands.

**Rule:** Always strip `\r` before passing a script to WSL. `Invoke-WslBash`
in `lib.ps1` does this automatically:

```powershell
$Script = $Script -replace "`r", ''
```

**Never call `wsl.exe -- bash -c ...` directly with a heredoc**. Always go
through `Invoke-WslBash`.

### 4. Inno Setup helpers must run at `ssPostInstall`, not `ssInstall`

**Symptom:** The PowerShell helpers can't find `helpers\lib.ps1` — Inno
reports "file not found".

**Cause:** `ssInstall` fires **before** the `[Files]` section has copied
files to the install directory. At that point `{app}\helpers\lib.ps1`
doesn't exist yet.

**Rule:** Run all helper orchestration at `ssPostInstall`. `CurStepChanged`
in `installer.iss` checks for this explicitly.

### 5. GitHub Actions Windows runners can't run WSL2

**Symptom:** Attempts to write a Windows end-to-end integration test fail
with "The attempted operation is not supported for the type of object
referenced" from `wsl --install`.

**Cause:** GitHub Actions `windows-latest` runners are Azure VMs. Nested
virtualization is **disabled**, so WSL2 (which requires the Hyper-V
hypervisor) cannot start inside them. The workflow can *compile* the `.exe`
but cannot *run* it end-to-end.

**Rule:** `build-windows.yml` compiles only. End-to-end Windows testing
requires a real Windows VM or bare-metal box. Contributors must test
Windows changes on their own machines before opening a PR.

### 6. Docker Hub rate limits anonymous pulls (and private images need auth)

**Symptom:** `test-linux.yml` fails with `toomanyrequests` or
`authentication required` when pulling `falconpulsar/core:latest`.

**Cause:** Docker Hub rate-limits anonymous pulls (100 per 6 hours per IP).
GitHub Actions runners share outbound IPs, so the limit gets hit quickly.
Additionally, FalconPulsar images are private in pre-release.

**Rule:** `test-linux.yml` logs in with `DOCKERHUB_USERNAME` /
`DOCKERHUB_TOKEN` org secrets before running the installer. When the
installer itself runs, it calls `fp_registry_ensure_access` which probes
pull access against `$FP_REGISTRY/core` and only prompts for credentials
if the probe fails with an auth error. After login, root's
`~/.docker/config.json` is copied into the `falconpulsar` user's home so
the stack can pull under the unprivileged account.

### 7. Passing credentials on the command line leaks them to any local user

**Symptom:** N/A — this is a pre-emptive rule, not an incident.

**Cause:** `argv` is visible via `/proc/<pid>/cmdline` to any local user.
Passing a password via `-AdminPass "..."` → `bash -c "... FP_ADMIN_PASS='...'
..."` would briefly expose the password to anyone who runs `ps` or reads
`/proc`.

**Rule:** `40-run-fp-installer.ps1` writes credentials to a temp env file
inside WSL, sources it, deletes it, then runs the bash installer. The
credentials never appear in argv.

### 8. The Windows upgrade detection must check the registry, not files

**Symptom:** Installer immediately shows "FalconPulsar is already installed,
click OK to upgrade" on a completely fresh VM.

**Cause:** A previous test run left files at `C:\Program Files\FalconPulsar\`
even though the install failed. `FileExists` returned true for `lib.ps1`, so
the wizard thought it was an upgrade.

**Rule:** `InitializeSetup` checks the Inno Setup uninstall registry key
(`HKLM\...\{AppId}_is1`), which is only written by Inno after a **completed**
install. File-based detection is unreliable.

### 9. macOS installers must run as the current user, not root

**Symptom:** Bind-mounts in `compose.yml` end up owned by `root`, and the
`core` container can't write to the database directory.

**Cause:** macOS Docker Desktop's bind-mount layer preserves the host UID.
If the installer runs as root, the database directory ends up `root:wheel`
and the container (running as `FP_UID=0`) still can't write because Docker
Desktop's VM maps `root` → a different UID inside its Linux VM.

**Rule:** `macos/install.sh` starts with `require_not_root`. The installer
is designed to run under the user's normal account, with `FP_UID=$(id -u)`.

### 10. The `falconpulsar-distro.txt` sentinel lets helpers share state

**Symptom:** When porting `20-install-distro.ps1` to support multiple
distros (Ubuntu 24.04, 22.04, Debian), later helpers couldn't know which
distro was actually installed.

**Cause:** Inno Setup runs each PowerShell helper as a **separate process**.
Variables set in one helper are not visible to the next. Inno passes command
line arguments, but those are fixed at call time.

**Rule:** `20-install-distro.ps1` writes the selected distro name to
`%TEMP%\falconpulsar-distro.txt`. Later helpers (`30-configure-distro`,
`40-run-fp-installer`, `50-register-shortcuts`) read it with a fallback
to probing WSL directly if the sentinel is missing.

### 11. `docker manifest inspect` is the right probe, not `docker pull`

**Symptom:** Early drafts of the registry detection used
`docker pull falconpulsar/core:latest` as the access probe, which (a) hit
Docker Hub rate limits for anonymous users, (b) downloaded hundreds of MB
before the first failure, and (c) partially populated the local image
cache even when the flow was aborted.

**Cause:** `docker pull` is a full pull. There's no "check if I can pull
without actually pulling" flag. But the OCI distribution spec has a
manifest endpoint that you can query with a HEAD-like request, and Docker
exposes that as `docker manifest inspect`. The manifest endpoint returns
just the image descriptor, not any layer blobs — kilobytes instead of
megabytes, and it doesn't count against Docker Hub's pull rate limit.

**Rule:** `fp_registry_probe` uses `docker manifest inspect
$FP_REGISTRY/core:$FP_VERSION` to classify access. Three possible outcomes:
`ok` (success), `auth-needed` (401 / "unauthorized" / "pull access
denied"), or `other` (network, DNS, not found, rate limited). Only auth
failures trigger the interactive credential prompt — network failures exit
immediately so the installer doesn't ask the user for a Docker Hub password
when their DNS is broken.

### 12. Never name a PowerShell loop variable `$home` (or any other automatic)

**Symptom:** `uninstall.ps1` ran, logged "Stopping containers...", then
silently did nothing. Containers / images / volumes survived. Log file
cut off mid-sentence.

**Cause:** `$HOME` is a PowerShell automatic variable. In Windows
PowerShell 5.1 it's marked `ReadOnly, AllScope`. `foreach ($home in $WslHomes)`
tries to assign to `$home` on each iteration — throws "Cannot overwrite
variable HOME because it is read-only or constant." With `$ErrorActionPreference
= 'Stop'` (set by `lib.ps1` in the caller's scope via dot-source), that's
a terminating error. The script halts between the "Stopping..." log line
and the loop body.

**Rule:** Do not name iteration variables after PowerShell automatic
variables: `$home`, `$host`, `$pid`, `$args`, `$error`, `$input`, `$null`,
`$pshome`, `$profile`, `$pwd`, `$this`, `$matches`. Use `$stackHome` /
`$targetPid` / etc. The `uninstall.ps1` script now has a global `trap`
at the top so any future silent halt writes its cause to the log instead
of leaving us guessing.

### 13. C# `ProcessStartInfo.StandardInput` defaults to CP1252 on Windows

**Symptom:** `ai-gateway` crash-loops with `UnicodeDecodeError: 'utf-8'
codec can't decode byte 0x97 in position 26` from Python's
`yaml.safe_load` reading `gateway.yaml`, after the file was (re)written
by a bash script piped from the Windows side.

**Cause:** Piping a bash script (e.g. a heredoc carrying `gateway.yaml`
content) to `wsl.exe -- bash` via
`proc.StandardInput.WriteAsync(script)`. .NET's `StandardInput` defaults
its encoding to `Console.InputEncoding`, which on Windows is the OEM
codepage — CP1252 on en-US. `U+2014` em-dash in the C# string literal
gets transliterated to a single byte `0x97` (CP1252's em-dash), bash
writes it verbatim into `gateway.yaml`, and Python can't decode it as
UTF-8.

**Rule:** Whenever piping bash scripts from C# via
`ProcessStartInfo.StandardInput`, set
`StandardInputEncoding = new UTF8Encoding(false)` explicitly. Also
prefer ASCII-only content in embedded scripts (replace em-dashes with
`--`) as belt-and-suspenders. `TrayApp.cs` does both on both pipe sites.

### 14. Inno Setup `[Files]` runs at `ssInstall`, not `ssPostInstall`

**Symptom:** Every Windows install ended with the HKCU PATH entry
pointing at `%LOCALAPPDATA%\falconpulsar\bin` but the folder was empty
and `fp` was "not recognized" in every shell.

**Cause:** `[Files]` deposits files during `ssInstall`. `CurStepChanged(ssPostInstall)`
fires *after* `[Files]` has run. A helper called from `ssPostInstall`
that does `Remove-Item -Recurse -Force %LOCALAPPDATA%\falconpulsar`
(intended to clean up prior-install artifacts) ends up wiping the files
Inno Setup just placed 200 ms earlier.

**Rule:** Cleanup of Windows-side install artifacts belongs in the
**uninstall** flow (`windows/helpers/uninstall.ps1` with `-Purge`), not
in the install flow. The Fresh-install pre-cleanup in `40-run-fp-installer.ps1`
only wipes *WSL-side* state, which is safe because the bash installer
recreates it afterwards.

### 15. Inno Setup `[Registry]` appends but never un-appends on uninstall

**Symptom:** Users who reinstalled repeatedly ended up with dozens of
copies of `%LOCALAPPDATA%\falconpulsar\bin` in their `HKCU\Environment\Path`.

**Cause:** The `[Registry]` directive
`ValueData: "{olddata};{localappdata}\falconpulsar\bin"` appends on each
install. Inno Setup has no automatic "remove-on-uninstall" for modified
registry values (only for values it created from scratch with
`uninsdeletevalue`). Uninstall left every appended copy in place; the
next install appended one more.

**Rule:** Prefer shipping a self-located binary (e.g., `%LOCALAPPDATA%\Microsoft\WindowsApps\fp.exe`,
which is on every Windows user's PATH by default since Win10 1709) over
registry Path manipulation. Our `uninstall.ps1` also scrubs any stale
`\falconpulsar` segments from `HKCU\Environment\Path` as a one-way
migration for users upgrading from earlier builds.

## Debugging tips

### Linux

```bash
# Verbose shell trace
bash -x linux/install.sh --mode docker

# Re-run individual sections by sourcing the libs
source shared/lib/common.sh
source shared/lib/checks.sh
check_ports

# Stack logs after install (service-user mode)
sudo -u falconpulsar docker compose -f /home/falconpulsar/compose.yml logs -f core

# Stack logs after install (per-user / WSL mode — run as the human user)
docker compose -f "$HOME/falconpulsar/compose.yml" logs -f core

# Install log
tail -f /tmp/falconpulsar-install.log
```

### macOS

```bash
# Tail container logs
cd ~/falconpulsar && docker compose logs -f

# Clean up fully between runs
cd ~/falconpulsar && docker compose down -v
rm -rf ~/falconpulsar
```

### Windows

1. Logs: `%TEMP%\falconpulsar-install.log` (from `lib.ps1`) and
   `%TEMP%\Setup Log YYYY-MM-DD #NNN.txt` (from Inno Setup)
2. Re-run a single helper manually:
   ```powershell
   cd "C:\Program Files\FalconPulsar\helpers"
   powershell -ExecutionPolicy Bypass -File .\40-run-fp-installer.ps1 `
       -Distro Ubuntu-24.04 `
       -InstallDir "C:\Program Files\FalconPulsar" `
       -AdminUser admin `
       -AdminPass 'your-password'
   ```
3. Inspect the distro from Windows (per-user mode — the normal case):
   ```powershell
   wsl -d Ubuntu-24.04 -- bash
   # inside, as the default user:
   docker ps
   cat ~/falconpulsar/compose.yml
   cat ~/falconpulsar/.env
   cat /tmp/falconpulsar-install.log
   ```
   Or as root if you need systemd / root-owned things:
   ```powershell
   wsl -d Ubuntu-24.04 -u root -- bash
   ps -p 1 -o comm=        # 'systemd' if /etc/wsl.conf systemd=true took effect
   cat /opt/falconpulsar-installer/linux/install.sh
   ```
4. Nuke and retry from scratch:
   ```powershell
   wsl --unregister Ubuntu-24.04
   Remove-Item "C:\Program Files\FalconPulsar" -Recurse -Force
   # then re-run FalconPulsar-Setup.exe
   ```
