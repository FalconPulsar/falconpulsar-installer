# System Requirements

The FalconPulsar installer enforces these minimum requirements at install time.
The installer **refuses to run** on anything not in the supported list and prints
a clear "your OS is not supported, please upgrade to ..." message.

The general rule is: **we support what upstream still supports**. Anything past
EOL upstream is not supported by FalconPulsar either.

## Supported operating systems

### Linux

| Distribution | Minimum version | Status |
|---|---|---|
| **Ubuntu** | 22.04 LTS (Jammy) | LTS, supported by Canonical until 2027-04 |
| | 24.04 LTS (Noble) | LTS, supported by Canonical until 2029-04 |
| | 25.10 (Questing) | Interim, supported until 2026-07 |
| **Debian** | 12 (Bookworm) | Stable, supported until 2026-06 + LTS to 2028 |
| | 13 (Trixie) | Stable, supported until 2028-08 + LTS to 2030 |
| **RHEL / Rocky / AlmaLinux** | 9.x | Full support until 2032-05 |
| | 10.x | Full support until 2035-05 |
| **Fedora** | 41 | Supported until ~2025-12 |
| | 42 | Supported until ~2026-06 |
| | 43 | Supported until ~2026-12 |
| **openSUSE Leap** | 15.6 (best-effort) | Tested but not the primary target |

**Architecture**: `x86_64` (amd64) **or** `arm64` (aarch64). Both first-class.

**Kernel**: 5.15 or newer. Kernel 5.10+ may work but is not tested.

**init system**: `systemd` 245 or newer. SysVinit, OpenRC, runit are not supported.

**Packages required during install**: `curl`, `tar`, `gzip`, `awk`, `bash` (4.x or
newer). The installer pulls Docker via `https://get.docker.com` if it's missing.

### Windows

| Edition | Minimum version | Status |
|---|---|---|
| **Windows 11** | 22H2 | Supported by Microsoft |
| | 23H2 | Supported by Microsoft |
| | 24H2 | Supported by Microsoft |
| **Windows 10** | 22H2 (last) | Supported by Microsoft until 2025-10. After that, **not supported by FalconPulsar**. |
| **Windows Server** | 2022 Standard / Datacenter | With WSL2 enabled |
| | 2025 Standard / Datacenter | With WSL2 enabled |

**Architecture**: `x64` (amd64). ARM64 Windows is not yet supported (Phase 3).

**Mandatory components**:

- **WSL2** with `systemd=true` in `/etc/wsl.conf`. The installer enables this if missing.
- **A WSL2 Linux distribution** — the installer installs Ubuntu 24.04 LTS if no compatible distro is present.
- **Docker Engine inside the WSL2 distro** — installed automatically by the installer. Docker Desktop is **not** required (and is not the default, due to its commercial-use licensing).

**Virtualization**: Hyper-V or hardware virtualization (VT-x / AMD-V) must be enabled in the BIOS/UEFI. WSL2 will not run otherwise.

### macOS

| Version | Minimum | Status |
|---|---|---|
| **macOS 14 Sonoma** | 14.0 | Supported by Apple |
| **macOS 15 Sequoia** | 15.0 | Supported by Apple |
| **macOS 16+** | (when released) | Auto-supported |

Older macOS versions (13 Ventura and earlier) are **not supported**. Apple no
longer provides security updates.

**Architecture**: Apple Silicon (M1, M2, M3, M4) **or** Intel x86_64 (2018+).

**Container runtime**: One of:

- **Docker Desktop** 4.27 or newer (recommended for Desktop users — note commercial-use licensing)
- **Colima** 0.6 or newer (free, no licensing complications, recommended for businesses)
- **Rancher Desktop** 1.13 or newer (free)
- **OrbStack** 1.0 or newer (paid for commercial use)

The installer **does not install** the container runtime on macOS. The user must
have one already. The installer detects which one is present and uses it.

## Hardware requirements

| Resource | Minimum | Recommended (production) |
|---|---|---|
| **CPU** | 2 cores | 4+ cores |
| **RAM** | 4 GB (Linux) / 8 GB (Windows / macOS — Docker overhead) | 16 GB |
| **Disk** | 10 GB free | 50 GB+ for the time-series database |
| **Network** | Outbound HTTPS to `docker.io`, `ghcr.io`, `get.docker.com` (during install) | (same) |

**FalconPulsar Gateway footprint:** the gateway image is ≈1.6 GB (Python +
analytics dependencies) versus ≈330 MB for Core — it is the largest single
component. It is installed by default because it powers Workspace commands
and standing watches (not just the AI assistant). On disk- or RAM-
constrained edge boxes you can decline it at install time (or `fp ai
disable` later) at the cost of those features; FPQ queries keep working
directly against Core.

For air-gapped deployments, use `FP_REGISTRY` + `FP_REGISTRY_USER` +
`FP_REGISTRY_PASS` env vars to point the installer at an internal
OCI-compliant mirror that has the FalconPulsar images pre-pulled.
The Windows installer exposes the same knobs through its Container
Registry wizard page. See
[ARCHITECTURE.md](ARCHITECTURE.md#credentials-for-cloud-native-registries)
for per-provider credential recipes.

## What is NOT supported

- **Linux**: Alpine, Slackware, Devuan, Void, Gentoo, NixOS, Arch (works but not officially supported), CentOS Stream (use Rocky/Alma instead), legacy CentOS 7, Ubuntu 20.04 and older, RHEL 8.x and older.
- **Windows**: Windows 10 builds older than 22H2, Windows 7/8/8.1, Windows Server 2019 and older.
- **macOS**: macOS 13 Ventura and older.
- **Architecture**: 32-bit x86, MIPS, RISC-V (Phase 3 candidate), POWER.
- **Container runtimes**: Podman is not officially supported (may work, untested), `chroot` / unshare-based runtimes are not supported.
- **Init systems other than systemd** on Linux.

## Why these specific cutoffs

- **Ubuntu 22.04** is the oldest LTS still in standard support and runs ~70% of production Ubuntu deployments today.
- **RHEL 9** is the current major version. RHEL 8 is in maintenance phase only and tooling around it (Docker, glibc, OpenSSL) is increasingly outdated.
- **Windows 10 22H2** is the last Windows 10 version. After Microsoft's EOL date, we drop support too.
- **Windows 11 22H2+** ensures WSL2 with systemd is available out of the box.
- **macOS 14+** because Apple's "current + previous 2 versions" support pattern means anything older is unpatched.
- **arm64** is first-class because Apple Silicon Macs and ARM servers (AWS Graviton, Ampere, Raspberry Pi 5) are increasingly common in industrial deployments.

If you need support for a version not listed here, open an issue. We will consider
back-porting support for specific customer requirements.
