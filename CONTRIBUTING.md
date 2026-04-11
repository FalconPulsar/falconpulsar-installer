# Contributing to FalconPulsar Installer

Thanks for your interest in improving the FalconPulsar installers. This document
covers the essentials — how to get a development environment going, how to test
changes on each platform, and what we look for in a pull request.

## Before you start

- **Security issues**: do not open a public issue. See [SECURITY.md](SECURITY.md)
  for the disclosure process.
- **Big changes**: open an issue first to discuss the approach. Small fixes
  (typos, single-file bug fixes, doc improvements) can go straight to a PR.
- **Code of conduct**: participation in this project is governed by the
  [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.

## Repository layout

```
falconpulsar-installer/
├── linux/        Bash installer for Linux servers
├── macos/        Bash installer for macOS (Intel + Apple Silicon)
├── windows/      Inno Setup + PowerShell installer for Windows
├── shared/       compose.yml, init schema, shared bash libraries
└── .github/      CI workflows
```

Each platform directory is self-contained and can be developed independently.
`shared/` is the single source of truth for the production `compose.yml` and the
shared bash helpers in `shared/lib/`.

**Before making any non-trivial change**, read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It explains the three-installer
model, the Windows → WSL2 → Linux delegation, the full environment variable
reference, and a list of real-world gotchas that will save you hours.

## Development setup

### Prerequisites

- `bash` 4.0+ and `shellcheck` for Linux / macOS work
- A Linux VM, container, or box to smoke-test the Linux installer
- A macOS 13+ machine for the macOS installer
- A Windows 10/11 machine (or VM) with WSL2 and [Inno Setup 6](https://jrsoftware.org/isdl.php)
  for the Windows installer

### Linting

```bash
shellcheck linux/install.sh macos/install.sh shared/lib/*.sh
```

CI runs the same command on every push.

## Testing changes

### Linux installer

The fastest feedback loop is to run the installer inside a disposable container.
This won't exercise systemd, but it catches the vast majority of bugs:

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

For systemd-mode testing, use a real VM — GitHub Actions runners can't nest
systemd, so this path cannot be exercised in CI.

### macOS installer

Run directly on the host. The installer creates a stack in `~/falconpulsar/`,
so cleanup between runs is just:

```bash
cd ~/falconpulsar && docker compose down -v
rm -rf ~/falconpulsar
```

### Windows installer

1. Build the `.exe` locally (requires Inno Setup 6):
   ```powershell
   cd windows
   .\scripts\build-assets.ps1
   & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
   ```
2. The compiled installer lands at `windows\Output\FalconPulsar-Setup.exe`.
3. Run it on a clean Windows VM. Do not test on your daily-driver machine —
   the installer registers a WSL2 distro and modifies system state.

See [windows/README-windows-build.md](windows/README-windows-build.md) for
more detail.

## How to make common changes

Recipes for the most frequent kinds of contribution. Each one tells you
which files to touch, in order, and how to verify.

### Add support for a new Linux distribution

1. **`shared/lib/checks.sh`** — `check_supported_os`: add the distro ID and
   minimum version to the whitelist.
2. **`linux/install.sh`** — if the distro needs distro-specific handling
   (e.g. `dnf` vs `apt`), add a branch in `install_docker_linux`.
3. **`REQUIREMENTS.md`** — add the distro to the supported list.
4. **Test** in a container:
   ```bash
   docker run --rm -it -v "$PWD":/installer:ro --privileged \
       <new-distro-image>:<version> \
       bash -c "apt-get update && bash /installer/linux/install.sh --mode docker"
   ```

### Add a new OS / hardware check

1. **`shared/lib/checks.sh`** — add the function (e.g. `check_swap`).
2. **`linux/install.sh`** AND **`macos/install.sh`** — call it from the main
   block in the right spot (usually right after `check_disk`).
3. **Test** on both Linux and macOS — don't assume a check that passes on
   Linux will pass on macOS; the underlying commands are often different.

### Add a new environment variable

1. **`shared/lib/prompts.sh`** or a direct `FP_*=${FP_*:-default}` line in
   `linux/install.sh` / `macos/install.sh` — declare it with a default.
2. **`shared/compose.yml`** — reference it as `${FP_*}` in the relevant
   service's `environment:` block.
3. **`docs/ARCHITECTURE.md`** — add a row to the environment variables
   reference table so future contributors know it exists.
4. **`README.md`** — if the variable is user-facing (e.g. `FP_LOG_LEVEL`),
   document it there too.

### Fix a bug in the Windows installer

1. **Figure out which helper is failing.** Check
   `%TEMP%\falconpulsar-install.log` on the affected VM first.
2. **Edit the helper** under `windows/helpers/`. Follow the existing patterns
   for `try`/`catch` and `Invoke-WslBash`.
3. **Test locally** — re-run the specific helper manually (see the
   "Debugging tips" section in
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#debugging-tips)) rather than
   the whole installer every time.
4. **Then rebuild the `.exe`** and run it on a clean Windows VM end-to-end
   before opening the PR.
5. **Important:** `.ps1` files must be pure 7-bit ASCII — see gotcha #1 in
   ARCHITECTURE.md. This will bite you if you copy/paste from Markdown.

### Change the production `compose.yml`

1. **`shared/compose.yml`** is the single source of truth. Edit it here.
2. **Verify** that both Linux and macOS installers copy the file verbatim
   (`install_compose_file` or equivalent) and don't templatize fields that
   are now dynamic.
3. **Lint** with `docker compose -f shared/compose.yml config` — this
   catches most schema errors without starting containers.
4. **Test** on at least one real stack (Linux VM is usually fastest).

### Add a new PowerShell helper to the Windows installer

1. Pick the next unused number in the sequence (the gap between existing
   helpers tells you where it runs): 00, 10, 20, 30, 40, 50.
2. **Copy `10-enable-wsl.ps1`** as a template — it has the correct
   `lib.ps1` sourcing, `try`/`catch` pattern, and `Invoke-WslBash` usage.
3. **`windows/installer.iss`** — add a `RunHelper` call in
   `CurStepChanged(ssPostInstall)`, passing the right arguments.
4. **Test** the helper in isolation first (see ARCHITECTURE.md Debugging
   Tips), then the full flow.

## PowerShell helper reference

Quick one-line summary of every helper for when you're navigating the
Windows installer. Full details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#powershell-helpers-execution-order).

| Helper | What it does |
|---|---|
| `lib.ps1` | Shared logging, WSL probes, `Invoke-WslBash` (the only correct way to run bash inside WSL) |
| `00-check-prereqs.ps1` | Admin, Windows build, x64, VT-x checks |
| `10-enable-wsl.ps1` | Enable WSL + VM Platform features, update kernel |
| `20-install-distro.ps1` | Install Ubuntu-24.04, write `falconpulsar-distro.txt` sentinel |
| `30-configure-distro.ps1` | Write `systemd=true` to `/etc/wsl.conf` |
| `40-run-fp-installer.ps1` | Stage `linux/` + `shared/` into WSL, run `linux/install.sh` |
| `50-register-shortcuts.ps1` | Create Start Menu shortcuts |
| `uninstall.ps1` | Terminate WSL distro on uninstall |

## Pull request guidelines

- **One logical change per PR.** If you're tempted to use "and" in the PR
  title, split it.
- **Describe what and why.** The diff shows *what*; the PR body should explain
  *why*. Link any issue the change closes.
- **Test on at least one platform.** Tell us which one in the PR body. Windows
  changes must be tested on a real Windows VM, not just CI.
- **No unrelated cleanup.** If you spot something to clean up while fixing a
  bug, open a separate PR.
- **Match the existing style.** Bash: shellcheck-clean, 4-space indent.
  PowerShell: strict mode, descriptive function names with approved verbs.

## Release process

Releases are cut from tagged commits on `main`. Follow the checklist below
in order — skipping steps is how we ship broken installers.

### Pre-release checklist

- [ ] `main` is green (all three workflows passing: `lint`, `test-linux`,
      `build-windows`)
- [ ] `shellcheck linux/install.sh macos/install.sh shared/lib/*.sh` is clean
- [ ] Linux installer tested end-to-end on at least one real Linux VM (not
      just a container) with `--mode systemd`
- [ ] macOS installer tested end-to-end on a real Mac
- [ ] Windows installer tested end-to-end on a clean Windows 11 VM — fresh
      install and upgrade-in-place flow
- [ ] `REQUIREMENTS.md` reflects any new supported OS versions
- [ ] `docs/ARCHITECTURE.md` updated if any architectural change
- [ ] `README.md` updated if any user-facing change

### Cutting the release

```bash
git tag v0.2.0
git push origin v0.2.0
```

This triggers `.github/workflows/release.yml`, which builds all three
installers and publishes them as assets on a GitHub Release. The unversioned
aliases (`install-linux.sh`, `install-macos.sh`, `FalconPulsar-Setup.exe`)
are copied from the versioned artifacts so the `get.falconpulsar.com/<platform>`
redirect URLs stay stable.

### Post-release verification

- [ ] GitHub Release page shows all four assets (linux, macos, windows .exe,
      init.example.json)
- [ ] `curl -fsSLI https://get.falconpulsar.com/linux` chains `302` →
      `302` → `200`
- [ ] `curl -fsSLI https://get.falconpulsar.com/macos` chains `302` →
      `302` → `200`
- [ ] `curl -fsSLI https://get.falconpulsar.com/windows` chains `302` →
      `302` → `200`
- [ ] A fresh `curl -fsSL https://get.falconpulsar.com/linux | sudo sh` on
      a clean VM installs cleanly
- [ ] Update release notes on the GitHub Release page with the highlights
      from this version

## Questions?

Open a discussion or email **contact@falconpulsar.com**.
