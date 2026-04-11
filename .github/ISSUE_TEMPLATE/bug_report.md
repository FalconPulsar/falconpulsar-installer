---
name: Bug report
about: Report a problem with the FalconPulsar installer
title: '[bug] '
labels: bug
assignees: ''
---

## Which installer?

- [ ] Linux (`install-linux.sh`)
- [ ] macOS (`install-macos.sh`)
- [ ] Windows (`FalconPulsar-Setup.exe`)

## What went wrong

A clear description of what you expected to happen and what actually happened.

## Steps to reproduce

1.
2.
3.

## Environment

- **OS and version:** (e.g. Ubuntu 24.04, macOS 14.2, Windows 11 23H2)
- **Architecture:** (x86_64 / arm64)
- **Installer version / tag:** (e.g. v0.1.0)
- **Docker version:** (output of `docker --version`, if relevant)

## Installer log

Paste the relevant portion of the installer log. Logs live at:

- **Linux / macOS:** stderr and stdout from the script. Re-run with
  `bash -x install.sh ...` if you need more detail.
- **Windows:** `%TEMP%\falconpulsar-install.log` and the Inno Setup log at
  `%TEMP%\Setup Log YYYY-MM-DD #NNN.txt`.

```
(paste log here, redact anything sensitive first)
```

## Additional context

Anything else that might help — screenshots, network setup, corporate proxy,
prior FalconPulsar installations on the same machine, etc.
