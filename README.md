# FalconPulsar Installer

[![lint](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/lint.yml/badge.svg)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/lint.yml)
[![test-linux](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/test-linux.yml/badge.svg)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/test-linux.yml)
[![build-macos](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-macos.yml/badge.svg)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-macos.yml)
[![build-windows](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-windows.yml/badge.svg)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-windows.yml)
[![Latest release](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/icterusicterus/894cadcfc17cc70a488bdfe8917f5df2/raw/release-installer.json)](https://github.com/FalconPulsar/falconpulsar-installer/releases)

![Linux](https://img.shields.io/badge/Linux-supported-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-supported-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-supported-success?logo=windows&logoColor=white)
![arch](https://img.shields.io/badge/arch-x64%20%7C%20arm64-informational)
![status](https://img.shields.io/badge/status-pre--release-orange)
[![license](https://img.shields.io/badge/license-AGPL%20v3-blue)](LICENSE)

![Designed by Humans · Built with AI](https://img.shields.io/badge/Designed_by_Humans-·_Built_with_AI-6E56CF)
![AI pair-programmers: Claude & Grok](https://img.shields.io/badge/AI_pair--programmers-Claude_·_Grok-6E56CF)

## Designed by humans · Built with AI

Every architectural decision, design choice, and product direction in
FalconPulsar is made and owned by its human maintainers. Implementation is
accelerated with AI coding assistants — primarily **Claude** (Anthropic) and
**Grok** (xAI) — and all code is human-directed, human-reviewed, and
human-approved before it ships.

This repository contains the installers that take a fresh Linux, macOS, or
Windows machine from zero to a running FalconPulsar **stack**. **This
repo is only the installer** — product usage and architecture for each runtime
component live in those repositories and on
[falconpulsar.com](https://falconpulsar.com).

### What gets installed (default install)

| Component | Image (default registry) | Ports (typical) |
|-----------|--------------------------|-----------------|
| **Core** | `falconpulsar/core` | 7433 REST, 7434 WS, 7435 pub/sub |
| **UI** | `falconpulsar/ui` | 8080 (nginx → Core + Gateway) |
| **AI Gateway** | `falconpulsar/ai-gateway` | 7436 (often bound to localhost; UI proxies) |
| **AI Engine** | `falconpulsar/ai-engine` | 8085 (bound to localhost by default) — data in `$FP_HOME/ai-engine-data` |

**Optional module** (opt-in during install on every platform):

| Module | Flag / profile | Default port | Notes |
|--------|----------------|--------------|--------|
| **Command Center** | `FP_COPILOT_ENABLED=true` → profile `copilot` | 8090 | Clean data; ops workspace |

Install also asks **sign-in security**: local users (default), SSO later, or SSO
now (Entra / Okta / generic OIDC). A **local break-glass admin** is always
created; policy is written to `$FP_HOME/auth-policy.json`.

### Build / run a single component by hand

If you are developing or debugging one service without the full installer,
use that component’s README (manual Docker and from-source steps):

| Component | Repository |
|-----------|------------|
| Core | [falconpulsar-core](https://github.com/FalconPulsar/falconpulsar-core#build-from-source-linux) |
| AI Gateway | [falconpulsar-ai-gateway](https://github.com/FalconPulsar/falconpulsar-ai-gateway#build-from-source-manual) |
| UI | [falconpulsar-ui](https://github.com/FalconPulsar/falconpulsar-ui#build-from-source-manual) |
| AI Engine | [falconpulsar-ai-engine](https://github.com/FalconPulsar/falconpulsar-ai-engine) |
| Command Center (optional) | [falconpulsar-copilot](https://github.com/FalconPulsar/falconpulsar-copilot) |

Compose file used by all platforms: [`shared/compose.yml`](shared/compose.yml).
Important secrets (generated or preserved by install): `FP_API_KEY`,
`FP_BRIDGE_TOKEN`, `FP_GATEWAY_SECRET`, `FP_CONFIRM_SECRET`, and
`FP_REQUIRE_SECRETS=1` so the gateway refuses to start without encryption/bridge
secrets in production.

Scope of **this** repo: prerequisite checks, container-engine setup, stack
file generation, first-run initialization, lifecycle hooks, and an
uninstaller. Every step is documented and reversible.

> **Status**: pre-release MVP. v0.x — installer behaviour may change.

---

## Install

> **Note**: FalconPulsar currently ships prerelease tags only, and GitHub's
> `releases/latest` alias excludes prereleases — URLs built on it (including
> the `get.falconpulsar.com` redirects) return 404 until a stable release is
> published. The commands below resolve the newest release, prereleases
> included, via the GitHub API.

### Linux

```bash
FP_TAG=$(curl -fsSL "https://api.github.com/repos/FalconPulsar/falconpulsar-installer/releases?per_page=1" | awk -F'"' '/"tag_name":/{print $4; exit}'); curl -fsSL "https://github.com/FalconPulsar/falconpulsar-installer/releases/download/${FP_TAG}/install-linux.sh" -o install-linux.sh; sudo bash install-linux.sh
```

> The installer is interactive (it prompts you to accept the legal terms).
> Download it to a file and run it, as above, so the prompts can read your
> keyboard. Piping straight into `sudo bash` gives the script no terminal,
> so the legal prompt auto-declines and the install cancels.

Installs the stack on Ubuntu, Debian, RHEL, Rocky, AlmaLinux, Fedora, or
openSUSE. Docker Engine is installed via `get.docker.com` if it isn't
already present.

To uninstall:

```bash
FP_TAG=$(curl -fsSL "https://api.github.com/repos/FalconPulsar/falconpulsar-installer/releases?per_page=1" | awk -F'"' '/"tag_name":/ {print $4; exit}')
curl -fsSL "https://github.com/FalconPulsar/falconpulsar-installer/releases/download/${FP_TAG}/uninstall-linux.sh" -o uninstall-linux.sh
sudo bash uninstall-linux.sh
# add `--purge` to also delete the local database
```

### macOS

**GUI installer (recommended):** download **FalconPulsar-Setup.dmg** from
the [newest release](https://github.com/FalconPulsar/falconpulsar-installer/releases),
open it, drag the `.app` into `/Applications`, and run it. Requires macOS 14
Sonoma or newer, Apple Silicon or Intel, and a container runtime already
installed (Docker Desktop, Colima, OrbStack, or Rancher Desktop — the
installer doesn't modify your Mac's system.)

**Headless / CI:**

```bash
FP_TAG=$(curl -fsSL "https://api.github.com/repos/FalconPulsar/falconpulsar-installer/releases?per_page=1" | awk -F'"' '/"tag_name":/ {print $4; exit}')
curl -fsSL "https://github.com/FalconPulsar/falconpulsar-installer/releases/download/${FP_TAG}/install-macos.sh" | bash
```

### Windows

Download **FalconPulsar-Setup.exe** from the
[newest release](https://github.com/FalconPulsar/falconpulsar-installer/releases)
and double-click. The GUI installer handles WSL2, Ubuntu, Docker, and the
stack end-to-end. Requires Windows 10 22H2 or Windows 11 with virtualization
(VT-x / AMD-V) enabled in the BIOS.

To uninstall: **Settings → Apps → FalconPulsar → Uninstall**, the tray
icon's "Uninstall FalconPulsar…" entry, or `fp uninstall` from any
PowerShell / cmd window.

---

## System requirements

| Platform | Minimum | Recommended | Prerequisites |
|---|---|---|---|
| **Linux** | 2 CPU, 4 GB RAM, 10 GB disk | 4 CPU, 16 GB RAM | Container engine is auto-installed |
| **macOS** | 8 GB RAM, 10 GB disk | 16 GB RAM | Docker Desktop / Colima / OrbStack / Rancher Desktop |
| **Windows** | 8 GB RAM, 10 GB disk | 16 GB RAM | Win 10 22H2+ or Win 11, VT-x / AMD-V in BIOS |

Full matrix (OS versions, kernel requirements, architecture notes) is in
[REQUIREMENTS.md](REQUIREMENTS.md).

## What the installer does

End to end, all three installers do the same six things:

1. **Check prerequisites** — OS version, RAM, disk, free ports
   (`8080`, `7433`, `7434`, `7435`, `7436`), virtualization support.
2. **Install / verify a container engine** — Docker Engine via
   `get.docker.com` on Linux, WSL2 + Docker inside Ubuntu on Windows.
   macOS expects a container runtime to already be present.
3. **Resolve the install user and stack directory.**
   - **Native Linux**: creates a dedicated `falconpulsar` system user;
     stack lives at `/home/falconpulsar/`.
   - **WSL (via the Windows installer)**: stack is owned by the WSL
     default user at `/home/<user>/falconpulsar/`. No service user is
     created.
   - **macOS**: stack lives under the invoking user's home at
     `~/falconpulsar/`.
4. **Generate the production stack files** — `compose.yml`, `.env`, and
   `gateway.yaml` — in the stack directory.
5. **Pull and start the containers** — `core`, `ui`, `ai-gateway`, and
   `ai-engine` (all standard; the FalconPulsar Gateway is required on
   every platform — it powers Workspace commands, standing watches, and
   the AI assistant. LLM providers and models are optional and configured
   post-install in ConfigHub), plus `copilot` (Command Center) when the
   optional module was selected. Wait for healthchecks to pass.
6. **Register lifecycle management** — optional systemd user unit on
   Linux, `restart: unless-stopped` on macOS, Start Menu shortcuts +
   system tray auto-start on Windows.

The installer requires `sudo` / admin briefly (package install,
user-creation on Linux, WSL configuration on Windows). Ongoing operation
never runs with elevated privileges. Every step has a matching removal
path in the uninstaller.

## Alternative container registries

By default, images are pulled from `falconpulsar` on Docker Hub. To use a
different registry — private mirror, air-gapped internal registry, AWS
ECR, Google Artifact Registry, Azure ACR — set `FP_REGISTRY` and provide
credentials via `FP_REGISTRY_USER` / `FP_REGISTRY_PASS`.

```bash
FP_TAG=$(curl -fsSL "https://api.github.com/repos/FalconPulsar/falconpulsar-installer/releases?per_page=1" | awk -F'"' '/"tag_name":/ {print $4; exit}')
curl -fsSL "https://github.com/FalconPulsar/falconpulsar-installer/releases/download/${FP_TAG}/install-linux.sh" -o install-linux.sh
FP_REGISTRY=ghcr.io/your-org/falconpulsar \
FP_REGISTRY_USER=your-github-username \
FP_REGISTRY_PASS=ghp_your_personal_access_token \
    sudo -E bash install-linux.sh
```

The Windows installer has a dedicated **Container Registry** wizard page
with a Test Connection button that runs a probe inside WSL.

Any OCI-compliant registry works. See the
[container registry section in ARCHITECTURE.md](ARCHITECTURE.md#credentials-for-cloud-native-registries)
for per-provider credential recipes.

## After the install

The installer ends when the stack is up and healthchecks pass. You can:

- Open **http://localhost:8080** — the FalconPulsar Web UI
- Run **`fp status`** in any terminal — local stack health
- See **[docs.falconpulsar.com](https://docs.falconpulsar.com/)** — how to
  use the product

## Uninstall

| Platform | Command |
|---|---|
| **Linux** | The `uninstall-linux.sh` one-liner from [Install → Linux](#linux), or `sudo bash /home/falconpulsar/uninstall.sh` (planted by the installer). <br> Add `--purge` to also delete the database. |
| **macOS** | Use the FalconPulsar menu bar app's "Uninstall FalconPulsar…" entry, or: <br> `bash ~/falconpulsar/uninstall.sh` |
| **Windows** | Settings → Apps → FalconPulsar → Uninstall, or the tray's "Uninstall" entry, or `fp uninstall` in any shell. |

All paths ultimately run the same cleanup: stop and remove the
containers and images, remove the stack directory (or preserve the
database unless `--purge` is specified), remove auto-start hooks and
Start Menu shortcuts, and (on `--purge`) remove the system user.

## Troubleshooting

Installation issues — corporate proxies, Docker Hub rate limits, air-gapped
installs, WSL2 + Docker Desktop integration, SmartScreen warnings,
SELinux / AppArmor, port conflicts, first-run init failures — are covered at
**[falconpulsar.com/install#troubleshooting](https://falconpulsar.com/install#troubleshooting)**.

If the guide doesn't cover your issue, please
[open an issue](https://github.com/FalconPulsar/falconpulsar-installer/issues/new/choose)
with the installer log attached. Log locations:

- macOS GUI installer and the Linux / macOS uninstallers:
  `/tmp/falconpulsar-install.log`
- Terminal installs print to the console — capture with
  `sudo bash install-linux.sh 2>&1 | tee install.log`
- Windows: `%TEMP%\falconpulsar-install.log`

---

## How it works (for developers)

FalconPulsar ships three installers, but **Linux is the canonical one**.
macOS is a bash variant that diverges only where the platform forces it.
Windows is an orchestration wrapper around the Linux installer running
inside WSL2 — there is no Windows-native install logic; every step that
actually deploys the stack is the same code that runs on a bare-metal
Linux server.

**Three rules that make this work:**

1. **`shared/compose.yml` is the one compose file.** All three installers
   copy it verbatim.
2. **`shared/lib/*.sh` is sourced by the Linux and macOS installers and
   uninstallers.** Shared logic lives here, not in platform-specific
   scripts.
3. **Windows does not implement install logic.** `installer.iss` and the
   PowerShell helpers set up WSL2 + Ubuntu, then hand off to
   `linux/install.sh`. A Linux bug is also a Windows bug.

The companion `fp` CLI (Go, in `console/`) is cross-compiled and shipped
with each installer. On Windows it's a thin Go wrapper that execs the
Linux `fp` binary inside WSL. Beyond `fp status` and `fp uninstall`, it
provides `fp open [ui|engine]`, `fp tui`, `fp update`, `fp logs`, and
`fp config edit` / `inspect` / `export` / `import`.

For the full reference — function call order, per-helper breakdown,
environment variable table, CI pipeline matrix, and real-world gotchas — see
**[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Repository layout

```
falconpulsar-installer/
├── README.md                    ← this file
├── REQUIREMENTS.md              ← supported OS versions, hardware specs
├── ARCHITECTURE.md              ← full contributor reference
├── LICENSE                      ← GNU AGPL v3
├── SECURITY.md                  ← responsible disclosure
├── CONTRIBUTING.md              ← dev setup, testing, PR guidelines
├── RELEASING.md                 ← cutting a release (maintainer-only)
├── CODE_OF_CONDUCT.md
│
├── linux/                       ← Linux installer (bash)
│   ├── install.sh               main installer
│   ├── uninstall.sh             uninstaller
│   ├── bootstrap.sh             curl-able dispatcher: picks install vs uninstall
│   └── systemd/
│       └── falconpulsar.service.template
│
├── macos/                       ← macOS installer (bash + Swift)
│   ├── install.sh               headless installer
│   ├── uninstall.sh             uninstaller
│   ├── build-dmg.sh             assembles the signed .dmg
│   ├── installer-app/           SwiftUI GUI installer
│   ├── menu-bar-app/            AppKit status-bar manager
│   └── pkg/                     .pkg builder and welcome/license panes
│
├── windows/                     ← Windows installer (Inno Setup + PS + C# + Go)
│   ├── installer.iss            Inno Setup script (Pascal)
│   ├── helpers/                 PowerShell orchestration (numbered pipeline)
│   ├── tray-app/                C# .NET 8 system-tray manager
│   ├── fp-wrapper/              Go wrapper that forwards fp.exe to WSL
│   └── assets/                  Wizard images, icons, license.rtf
│
├── console/                     ← fp CLI (Go)
│   ├── cmd/fp/                  main entry point
│   └── internal/
│       ├── cli/                 command definitions (cobra)
│       ├── tui/                 terminal UI (tview)
│       ├── actions/             compose/docker operations
│       ├── api/                 FalconPulsar REST client
│       ├── auth/                admin-password authentication
│       └── configbackup/        encrypted config export/import
│
├── shared/                      ← used by all installers
│   ├── compose.yml              production docker-compose file
│   ├── gateway.yaml             AI-gateway default config
│   ├── nginx.conf               reverse-proxy config inside the UI container
│   ├── init.example.json        rich init-schema reference
│   └── lib/                     shared bash libraries
│       ├── common.sh            colors, logging, error handling
│       ├── checks.sh            OS, RAM, disk, port checks
│       ├── prompts.sh           interactive prompts
│       ├── bootstrap.sh         first-run admin + token bootstrap
│       ├── auth.sh              admin-password challenge
│       ├── registry_auth.sh     docker-registry login probe
│       ├── fpcli.sh             fp CLI installer (downloads/copies to
│       │                        ~/falconpulsar/bin + PATH append)
│       └── existing.sh          detect prior installs
│
└── .github/
    ├── workflows/               CI: lint, test-linux, build-fp,
    │                            build-macos, build-windows, release
    └── scripts/
        └── bundle.sh            produces the single-file install bundles
```

## How to develop

### Linting

```bash
shellcheck -x -P shared/lib -e SC1091 \
    linux/install.sh linux/uninstall.sh linux/bootstrap.sh \
    macos/install.sh macos/uninstall.sh \
    scripts/sync-version.sh \
    shared/lib/common.sh shared/lib/checks.sh shared/lib/prompts.sh \
    shared/lib/bootstrap.sh shared/lib/registry_auth.sh shared/lib/auth.sh \
    shared/lib/fpcli.sh shared/lib/existing.sh
```

CI runs the same command on every push.

### Smoke-testing the Linux installer locally

```bash
docker run --rm -it \
    -v "$PWD":/installer:ro \
    --privileged \
    ubuntu:24.04 \
    bash -c "
        apt-get update && apt-get install -y curl sudo
        bash /installer/linux/install.sh --mode docker
    "
```

### Building platform installers locally

- **macOS DMG**: `./macos/build-dmg.sh` (requires Xcode tooling)
- **Windows .exe**: see
  [windows/README-windows-build.md](windows/README-windows-build.md)
  (requires Windows + Inno Setup 6)
- **fp CLI**: `cd console && go build ./cmd/fp`

Full contributor guide: **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## Releases

CI builds release artifacts on every push of a `v*` tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This produces a GitHub Release with:

- `linux.sh` — the **bootstrap dispatcher** for `curl | bash` installs
- `install-linux.sh` — bundled Linux installer (self-contained)
- `uninstall-linux.sh` — bundled Linux uninstaller (self-contained)
- `install-macos.sh` — bundled macOS headless installer
- `FalconPulsar-Setup.dmg` — macOS GUI installer
- `FalconPulsar-Setup.exe` — Windows GUI installer
- Versioned copies of every asset (`linux-v<tag>.sh`, etc.) alongside
  the unversioned "always-latest" aliases

The unversioned aliases back the stable redirects at
`https://get.falconpulsar.com/<platform>` so end users always pull the
current release without URL changes between versions. Those redirects
resolve through GitHub's `releases/latest` alias, which excludes
prereleases — while only prerelease tags exist they return 404, so the
[Install](#install) section resolves the newest release via the GitHub
API instead.

Only the **two newest releases are retained** — the prune-releases
workflow deletes older releases and their tags, so assets and download
URLs for older versions disappear.

The macOS DMG is signed with a Developer ID Application certificate and
notarized by Apple — double-clicking the download does not trigger a
Gatekeeper warning. The DMG is **best-effort**: if notarization fails,
the release still publishes without it, and a warning annotation on the
release run marks the gap. Maintainers cutting a release should read
**[RELEASING.md](RELEASING.md)** for the secret setup and verification
steps.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
for the dev setup, how to test on each platform, and PR guidelines. All
participants are expected to follow our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Security

If you believe you have found a security vulnerability, **please do not
open a public issue**. See [SECURITY.md](SECURITY.md) for the responsible
disclosure process.

## License

Licensed under the **[GNU Affero General Public License v3.0](LICENSE)**.

You are free to use, modify, and redistribute this installer under the
terms of the AGPL v3. Note the key AGPL clause: if you run a modified
version of this code as a network-accessible service, you must make the
corresponding source code available to users of that service. See the
[full license text](LICENSE) for the exact terms.

FalconPulsar is developed by the FalconPulsar team.
Learn more at **[falconpulsar.com](https://falconpulsar.com)**.
