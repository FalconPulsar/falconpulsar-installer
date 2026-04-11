# FalconPulsar Installer

[![lint](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/lint.yml)
[![test-linux](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/test-linux.yml/badge.svg?branch=main)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/test-linux.yml)
[![build-windows](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-windows.yml/badge.svg?branch=main)](https://github.com/FalconPulsar/falconpulsar-installer/actions/workflows/build-windows.yml)

![Linux](https://img.shields.io/badge/Linux-supported-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-supported-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-supported-success?logo=windows&logoColor=white)
![arch](https://img.shields.io/badge/arch-x64%20%7C%20arm64-informational)
![status](https://img.shields.io/badge/status-pre--release-orange)
[![license](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![release](https://img.shields.io/github/v/release/FalconPulsar/falconpulsar-installer?display_name=tag&sort=semver)](https://github.com/FalconPulsar/falconpulsar-installer/releases)

**Self-host FalconPulsar in 3 minutes. One command, your infrastructure,
no cloud account, no credit card, no telemetry.**

FalconPulsar is a high-performance time-series database. This repository
contains the source code for the three official installers that take a fresh
machine from zero to a running FalconPulsar stack.

Learn more at **[falconpulsar.com](https://falconpulsar.com)** •
Full install guide at **[falconpulsar.com/install](https://falconpulsar.com/install)**

> **Status**: pre-release. v0.x — APIs and behaviour may change.

---

## Install in 3 minutes

### Linux

```bash
curl -fsSL https://get.falconpulsar.com/linux | sudo sh
```

Works on Ubuntu, Debian, RHEL, Rocky, AlmaLinux, Fedora, and openSUSE. The
installer installs Docker Engine via the official `get.docker.com` script if
it's not already present.

### macOS

```bash
curl -fsSL https://get.falconpulsar.com/macos | bash
```

Requires macOS 13 Ventura or newer, Apple Silicon or Intel. A container
runtime (Docker Desktop, Colima, OrbStack, or Rancher Desktop) must already
be installed — the installer doesn't touch your Mac's system.

### Windows

Download **[FalconPulsar-Setup.exe](https://get.falconpulsar.com/windows)**
and double-click. The GUI installer handles WSL2, Ubuntu, Docker, and the
FalconPulsar stack end-to-end. Requires Windows 10 22H2 or Windows 11 with
VT-x / AMD-V enabled in the BIOS.

---

## System requirements

| Platform | Minimum | Recommended | Prerequisites |
|---|---|---|---|
| **Linux** | 2 CPU, 4 GB RAM, 10 GB disk | 4 CPU, 16 GB RAM | Container engine is auto-installed |
| **macOS** | 4 GB RAM, 10 GB disk | 8 GB RAM | Docker Desktop / Colima / OrbStack / Rancher Desktop |
| **Windows** | 4 GB RAM, 10 GB disk | 8 GB RAM | Win 10 22H2+ or Win 11, VT-x / AMD-V in BIOS |

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full support matrix —
supported OS versions, architectures, kernel requirements, and hardware
minimums.

## What the installer does

Designed for transparency. Every step is documented up-front, reversible,
and runs with the minimum privileges required. End to end, all three
installers do the same six things:

1. **Check prerequisites** — OS version, RAM, disk, free ports
   (`8080`, `7433`, `7434`, `7436`), virtualization support.
2. **Install / verify a container engine** — Docker Engine via
   `get.docker.com` on Linux, WSL2 + Docker inside Ubuntu on Windows.
   macOS expects a container runtime to already be present.
3. **Create a dedicated `falconpulsar` user** with its own home directory
   (`/home/falconpulsar/` on Linux, `~/falconpulsar/` on macOS,
   `\\wsl.localhost\Ubuntu\home\falconpulsar\` on Windows).
4. **Generate the production stack files** — `compose.yml`, `.env`, and
   optionally `init.json` — under the falconpulsar user's home directory.
5. **Pull and start the containers** — `core`, `ui`, `ai-gateway` from
   [Docker Hub](https://hub.docker.com/u/falconpulsar). Wait for
   healthchecks to pass.
6. **Register lifecycle management** — systemd user unit on Linux,
   `restart: always` on macOS, Start Menu shortcuts on Windows.

**Nothing runs as root.** The installer needs `sudo` briefly for user
creation, Docker installation, and systemd-unit registration on Linux.
Everything else — including every ongoing operation — runs as the
unprivileged `falconpulsar` user. Every step is reversible via the bundled
`uninstall.sh` scripts or the Windows uninstaller.

## Alternative container registries

By default the installer pulls images from **`docker.io/falconpulsar`** on
Docker Hub. If you need to pull from somewhere else — a private mirror,
an air-gapped internal registry, or a cloud-native registry like AWS ECR,
Google Artifact Registry, or Azure ACR — set `FP_REGISTRY` to the new
prefix and provide credentials via `FP_REGISTRY_USER` / `FP_REGISTRY_PASS`.

```bash
FP_REGISTRY=ghcr.io/your-org/falconpulsar \
FP_REGISTRY_USER=your-github-username \
FP_REGISTRY_PASS=ghp_your_personal_access_token \
    curl -fsSL https://get.falconpulsar.com/linux | sudo -E sh
```

The Windows installer has a dedicated **"Container Registry"** page with a
Test Connection button that runs a probe inside WSL before you continue.

Any OCI-compliant registry works — Docker Hub, GHCR, Quay, Harbor,
GitLab, AWS ECR (public or private), GCR / Google Artifact Registry,
Azure ACR, or a self-hosted mirror. See the
[container registry section in ARCHITECTURE.md](docs/ARCHITECTURE.md#credentials-for-cloud-native-registries)
for per-provider token recipes.

## After the install

Open **[http://localhost:8080](http://localhost:8080)** in any browser.
Log in with the admin credentials you set during install.

Next steps once you're in:

- Create your first **asset** (plant, area, equipment)
- Add a **datasource** — OPC-UA, Modbus TCP/RTU, MQTT, EtherNet/IP, or S7
- Map series to datasource tags and start collecting time-series data

Full product documentation lives at
**[falconpulsar.com/docs](https://falconpulsar.com/docs)**.

## Troubleshooting

For installation issues — corporate proxies, Docker Hub rate limits,
air-gapped installs, WSL2 + Docker Desktop integration, SmartScreen
warnings, SELinux / AppArmor, port conflicts, first-run init failures —
see the full troubleshooting guide at
**[falconpulsar.com/install#troubleshooting](https://falconpulsar.com/install#troubleshooting)**.

If the guide doesn't cover your issue, please
[open an issue](https://github.com/FalconPulsar/falconpulsar-installer/issues/new/choose)
with the installer log attached.

---

## How it works (for developers)

FalconPulsar ships three installers, but **Linux is the canonical one**.
macOS is a bash variant that diverges only where the platform forces it,
and Windows is an orchestration wrapper around the Linux installer running
inside WSL2. There is no Windows-native install logic — every step that
actually deploys the stack is the same code that runs on a bare-metal
Ubuntu server.

**Three rules that make this work:**

1. **`shared/compose.yml` is the one compose file.** All three installers
   copy it verbatim.
2. **`shared/lib/*.sh` is sourced by both Linux and macOS.** Shared logic
   lives here, not in platform-specific scripts.
3. **Windows does not implement install logic.** `installer.iss` and the
   PowerShell helpers set up WSL2 + Ubuntu + systemd, then hand off to
   `linux/install.sh`. A Linux bug is also a Windows bug.

For the full reference — function call order, per-helper breakdown, env
var table, CI pipeline matrix, and real-world gotchas — see
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Repository layout

```
falconpulsar-installer/
├── README.md                  ← this file
├── REQUIREMENTS.md            ← supported OS versions, hardware specs
├── LICENSE                    ← Apache 2.0
├── SECURITY.md                ← responsible disclosure
├── CONTRIBUTING.md            ← dev setup, testing, PR guidelines
├── CODE_OF_CONDUCT.md
│
├── linux/                     ← Linux installer (bash)
│   ├── install.sh
│   ├── uninstall.sh
│   └── systemd/
│       └── falconpulsar.service.template
│
├── macos/                     ← macOS installer (bash)
│   ├── install.sh
│   └── uninstall.sh
│
├── windows/                   ← Windows GUI installer (Inno Setup)
│   ├── installer.iss
│   ├── helpers/               PowerShell scripts called by Inno Setup
│   └── assets/                Icons, banner, license text
│
├── shared/                    ← Files used by all three installers
│   ├── compose.yml            production docker-compose file
│   ├── init.example.json      rich init schema (FP_INIT_CONFIG)
│   └── lib/                   shared bash libraries
│       ├── common.sh          colors, logging, error handling
│       ├── checks.sh          OS, RAM, disk, port checks
│       └── prompts.sh         interactive password / confirmation prompts
│
└── .github/workflows/         CI: lint, test, release
```

## How to develop

### Linting (locally)

```bash
shellcheck linux/install.sh macos/install.sh shared/lib/*.sh
```

### Smoke testing the Linux installer locally

```bash
# Start a clean Ubuntu container, mount the repo, run the installer
docker run --rm -it \
    -v "$PWD":/installer:ro \
    --privileged \
    ubuntu:24.04 \
    bash -c "
        apt-get update && apt-get install -y curl sudo
        bash /installer/linux/install.sh --mode docker
    "
```

### Building the Windows installer locally

See [windows/README-windows-build.md](windows/README-windows-build.md).
Requires a Windows machine (or VM) with Inno Setup 6 installed.

Full contributor guide: **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## Releases

CI builds release artifacts on every push of a `v*` tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This produces a GitHub Release with:

- `install-linux-v0.1.0.sh` — the bundled Linux installer
- `install-macos-v0.1.0.sh` — the bundled macOS installer
- `FalconPulsar-Setup-v0.1.0.exe` — the compiled Windows GUI installer
- `init.example.json` — the rich init schema template

Stable unversioned aliases are published alongside the versioned assets so
the `get.falconpulsar.com/*` redirects always resolve to the latest release:

- `https://get.falconpulsar.com/linux` → latest `install-linux.sh`
- `https://get.falconpulsar.com/macos` → latest `install-macos.sh`
- `https://get.falconpulsar.com/windows` → latest `FalconPulsar-Setup.exe`

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
for the dev setup, how to test on each platform, and PR guidelines. All
participants are expected to follow our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Security

If you believe you've found a security vulnerability, **please do not open
a public issue**. See [SECURITY.md](SECURITY.md) for the responsible
disclosure process.

## License

Licensed under the **[Apache License 2.0](LICENSE)**. You are free to use,
modify, and redistribute this installer in accordance with the license
terms.

FalconPulsar is developed by the FalconPulsar team.
Learn more at **[falconpulsar.com](https://falconpulsar.com)**.
