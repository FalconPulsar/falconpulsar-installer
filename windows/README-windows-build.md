# Building the Windows installer

The Windows installer (`FalconPulsar-Setup-vX.Y.Z.exe`) is produced by
**Inno Setup 6** from `installer.iss`. CI builds it on every push via the
`build-windows` GitHub Actions workflow, but you can also compile it
locally on a Windows machine for testing before pushing.

## What gets built

A single `.exe` file at `windows/Output/FalconPulsar-Setup-{version}.exe`.
It contains:

- `linux/install.sh` + `linux/uninstall.sh` + the systemd unit template
- `shared/compose.yml` + `shared/gateway.yaml` + `shared/nginx.conf`
  + `shared/init.example.json` + `shared/lib/*.sh`
- `windows/helpers/*.ps1` (the 12 staged PowerShell helpers below)
- `windows/tray-app/publish/FalconPulsarTray.exe` (self-contained .NET 8 tray)
- `console/dist/fp-windows-amd64.exe` (the Go fp.exe WSL wrapper)
- `console/dist/fp-linux-amd64` (the Linux fp binary, staged into WSL at install)
- `windows/assets/license.rtf`, wizard BMPs, icons
- A copy of `README.md` and `REQUIREMENTS.md` for reference

The PowerShell helpers run during install in this order (full reference
in [ARCHITECTURE.md](../ARCHITECTURE.md#powershell-helpers-execution-order)):

| # | Helper | What it does |
|---|---|---|
| — | `lib.ps1` | Shared logging, WSL probes, `Invoke-WslBash` |
| 00 | `00-check-prereqs.ps1` | Windows version, edition, x64, virtualization |
| 05 | `05-detect-environment.ps1` | Early-wizard probe of WSL state, Docker Desktop, disk |
| 06 | `06-detect-existing-install.ps1` | Detect a prior FalconPulsar install (populates the Existing-Install wizard page) |
| 10 | `10-enable-wsl.ps1` | Enables WSL2 + VirtualMachinePlatform features |
| 20 | `20-install-distro.ps1` | Installs Ubuntu 24.04 (or reuses an existing compatible distro) |
| 30 | `30-configure-distro.ps1` | Sets `systemd=true` in `/etc/wsl.conf` |
| 40 | `40-run-fp-installer.ps1` | Resolves the WSL default user, stages + runs the bash installer inside the distro |
| 45 | `45-verify-health.ps1` | Post-install container + REST API health probe |
| 50 | `50-register-shortcuts.ps1` | Start Menu shortcuts that wrap `wsl.exe` calls |
| — | `uninstall.ps1` | Full two-sided cleanup (WSL + Windows mirror + registry) on uninstall |

The installer is **idempotent** — re-running it after a Windows reboot
picks up where it left off because every helper checks state before
acting.

## Building locally on Windows

### 1. Install Inno Setup 6

Download from <https://jrsoftware.org/isdl.php>. The "QuickStart Pack"
includes the IDE and the command-line compiler. Free for any use,
including commercial.

Or via Chocolatey:

```powershell
choco install innosetup
```

This installs `iscc.exe` (the command-line compiler) at
`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`.

### 2. Generate wizard images

The Inno Setup script references two BMP files (`windows/assets/header.bmp`
and `windows/assets/welcome.bmp`) that are **gitignored** because they're
generated from `windows/assets/falcon-logo.png` on every build. Run the
generator first:

```powershell
& windows\scripts\build-assets.ps1
```

This produces both BMPs from the source PNG using `System.Drawing` — no
ImageMagick or other external dependency. Re-run it any time you change
the logo source file.

### 3. Compile

From a PowerShell prompt at the **repo root** (not inside `windows/`):

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\installer.iss
```

The `.iss` script uses **relative paths** like `..\linux\install.sh` so
you must invoke `ISCC.exe` with the script path as a relative argument
from the repo root, not from `windows/`.

The compiled `.exe` lands at:

```
windows\Output\FalconPulsar-Setup-0.1.0.exe
```

### 3. Run it

Double-click `FalconPulsar-Setup-0.1.0.exe`. The first time you run an
unsigned installer, **SmartScreen** will show a blue "Windows protected
your PC" dialog. Click **More info → Run anyway** to proceed. This
warning is expected for v0.1 — code signing is deferred until v0.x →
v1.0.

The installer needs **admin** rights (it enables Windows features,
installs WSL, and creates Start Menu shortcuts in the All Users group).
UAC will prompt for elevation.

## Building in CI

The `.github/workflows/build-windows.yml` workflow runs on every push
to `main` and on every `v*` tag. It:

1. Spins up a `windows-latest` runner
2. Installs Inno Setup 6 via `choco install innosetup -y`
3. Compiles `windows/installer.iss`
4. Uploads the resulting `.exe` as a workflow artifact
5. On `v*` tags, attaches the `.exe` to the GitHub Release

The artifact lives under the workflow run page → **Artifacts** →
`FalconPulsar-Setup-windows`. Download it for testing on a real Windows
box (or a Windows VM).

## Testing the installer

There is **no automated end-to-end test** for the Windows installer in CI
— the GitHub Actions Windows runners do not allow nested virtualization
(VT-x), so we can't actually start WSL2 inside them. The CI workflow only
verifies that the `.iss` script *compiles* and produces a valid `.exe`.

To test for real you need a Windows machine or a Windows VM with nested
virt enabled (VMware Workstation, Hyper-V on a host that supports it,
Parallels on Apple Silicon won't work — Windows ARM is Phase 3). The
quickest dev loop:

1. Spin up a fresh Windows 11 VM (or use the free [Windows dev VM](https://developer.microsoft.com/en-us/windows/downloads/virtual-machines/))
2. Mount or copy the compiled `.exe` to the VM
3. Run it, watch the install log at `%TEMP%\Setup Log YYYY-MM-DD #NNN.txt`
4. After install, snapshot the VM so you can revert and re-test

## Troubleshooting

### "Setup files are corrupted"

Usually means the bundled bash installer paths in `[Files]` are wrong.
Inno Setup resolves them relative to the directory containing
`installer.iss`, so `..\linux\install.sh` means `<repo-root>\linux\install.sh`.
Make sure you're compiling from the repo root.

### Pre-flight check fails on a real Win 11 box

Check `%TEMP%\Setup Log ...txt` for the helper output. The most common
causes are:

- Hardware virtualization (VT-x) disabled in BIOS — enable it and reboot
- Windows 11 Home build older than 22H2 — update Windows
- Hyper-V already running another hypervisor that conflicts — disable
  the third-party hypervisor

### `wsl --install` fails

This usually means Windows is missing optional updates. Run
`Get-WindowsUpdate` (RSAT) or simply check Windows Update. WSL2 also
requires the **Windows Subsystem for Linux Update Package**, which
`wsl --update` installs automatically.

### Bash installer fails inside WSL with "pull access denied"

The user needs read access to the private `falconpulsar/*` registry
repos. The Windows installer's **Container Registry** wizard page
collects a registry URL + optional username / password and its
**Test Connection** button probes access before committing to the
install. That probe lives inline in `installer.iss`
(`RegistryTestClick`), not in a helper script.

If the installer gets past that page and still fails deeper in the
WSL handoff:

```powershell
# Log in manually inside the distro, then re-run the installer:
wsl -d Ubuntu-24.04 -u root -- docker login
# enter your Docker Hub (or alternative registry) username + token
```

## Code signing (deferred to v1.0)

The unsigned `.exe` triggers SmartScreen on first run for every user
who downloads it, until enough downloads accumulate to "warm up" the
SmartScreen reputation. This is acceptable for a private pre-release
but not for v1.0.

When we get a code signing certificate, populate the `SignTool` line in
`installer.iss`:

```ini
SignTool=signtool sign /fd sha256 /tr http://timestamp.digicert.com $f
```

and configure `signtool.exe` to use a certificate from the cert store
(EV cert or KSP-backed cert preferred — they bypass SmartScreen
immediately, regular OV certs need warmup).
