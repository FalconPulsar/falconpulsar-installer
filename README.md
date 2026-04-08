# FalconPulsar Installer

Source code for the FalconPulsar installers — the things that take a fresh machine
from "no Docker, no FalconPulsar" to "FalconPulsar is running and ready to use".

This repository **contains the source** for the installers. The compiled / packaged
installer artifacts (`FalconPulsar-Setup.exe`, install scripts) are produced by CI
and published to **GitHub Releases** on each tagged version.

> **Status**: pre-release. v0.x — APIs and behaviour may change. Private repo until
> v1.0.

## Which installer do I use?

| Platform | Installer | How to run |
|---|---|---|
| **Linux** (Ubuntu / Debian / RHEL / Rocky / Alma / Fedora / openSUSE) | `linux/install.sh` | `curl -fsSL https://get.falconpulsar.com/linux \| sh` |
| **macOS** (13 Ventura or newer, Apple Silicon or Intel) | `macos/install.sh` | `curl -fsSL https://get.falconpulsar.com/macos \| sh` |
| **Windows** (10 22H2 or 11, with WSL2 enabled) | `windows/installer.iss` (compiled to `FalconPulsar-Setup.exe`) | Download the `.exe` from [Releases](https://github.com/FalconPulsar/falconpulsar-installer/releases) and double-click |

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full list of supported OS versions
and minimum hardware specs.

## What the installer does

End to end, all three installers do the same six things:

1. **Check prerequisites** — OS version, RAM, disk, ports, virtualization support.
2. **Install / verify Docker** — install Docker Engine on Linux (via `get.docker.com`)
   or detect / install it inside WSL2 on Windows. macOS expects Docker Desktop
   (or Colima / Rancher Desktop) already present.
3. **Create a non-root `falconpulsar` user** with a dedicated home directory.
   On macOS, use the current user's `~/falconpulsar/` instead.
4. **Generate the production stack files** — `compose.yml`, `.env`, optionally
   `init.json` — in the falconpulsar user's home directory.
5. **Pull and start the containers** — `core`, `ui`, `ai-gateway` from
   [Docker Hub](https://hub.docker.com/u/falconpulsar). Wait for healthchecks
   to pass.
6. **Register lifecycle management** — systemd user unit on Linux (optional),
   `restart: always` on macOS, Start Menu shortcuts and a Task Scheduler entry on
   Windows.

After install, the user opens `http://localhost:8080` in any browser to log in to
the Web UI.

**Nothing runs as root**. The installer needs sudo briefly during user creation,
Docker installation, and systemd-unit registration on Linux. Everything else,
including all ongoing operations, runs as the `falconpulsar` user.

See the per-platform READMEs for the details:

- [linux/](linux/) — Linux server installer (Bash)
- [macos/](macos/) — macOS installer (Bash)
- [windows/](windows/) — Windows GUI installer (Inno Setup) — coming in Phase 2

## Repository layout

```
falconpulsar-installer/
├── README.md                  ← this file
├── REQUIREMENTS.md            ← supported OS versions, hardware specs
├── LICENSE                    ← TBD before public release
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
├── windows/                   ← Windows GUI installer (Inno Setup) — Phase 2
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
# Bash scripts
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
        apt-get update && apt-get install -y curl sudo systemd
        bash /installer/linux/install.sh
    "
```

### Building the Windows installer locally

See [windows/README-windows-build.md](windows/README-windows-build.md). Requires a
Windows machine (or Windows VM) with Inno Setup 6 installed.

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

The `falconpulsar-site` web property serves convenience redirect URLs:

- `https://get.falconpulsar.com/linux` → latest `install-linux-*.sh`
- `https://get.falconpulsar.com/macos` → latest `install-macos-*.sh`
- `https://get.falconpulsar.com/windows` → latest `FalconPulsar-Setup-*.exe`

## License

License is **TBD before the v1.0 public release**. Currently this repo is private
and "all rights reserved" — no permission is granted to copy, redistribute, or
fork until a license is chosen.
