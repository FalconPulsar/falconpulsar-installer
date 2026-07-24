# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# 20-install-distro.ps1 -- Ensure a compatible Linux distro is installed
#                        inside WSL2.
#
# If the named distro (default Ubuntu-24.04) is already registered, this is
# a fast no-op. If a *different* compatible distro is already present
# (Ubuntu 22.04+, Debian 12+) we'll use that instead -- no need to install
# a second one.
#
# Otherwise: `wsl --install -d Ubuntu-24.04 --no-launch` downloads and
# registers the distro non-interactively. We then run a tiny `true` command
# inside it to trigger first-boot user creation; the WSL2 install image
# normally interrupts at this point asking for a UNIX username, but on
# Win11 22H2+ the --no-launch flag suppresses that and we can run the
# distro as root for the bootstrap.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step "Ensuring WSL distro: $Distro"

# Anything in this list will satisfy the requirement -- they're all
# supported per REQUIREMENTS.md and the bash installer will work fine
# inside any of them.
$compatibleDistros = @(
    'Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu',
    'Debian',
    'Rocky', 'AlmaLinux', 'rhel'
)

$existing = Get-WslDistros
# @() guards the zero-distro case: under Set-StrictMode a bare .Count on a
# null/AutomationNull return throws PropertyNotFoundStrict (broke clean
# installs). Matches the pattern in 05-detect-environment.ps1.
if (@($existing).Count -gt 0) {
    Write-Info "Existing WSL distros: $($existing -join ', ')"
} else {
    Write-Info 'No WSL distros currently registered'
}

# Already have the requested one? Done.
if ($existing -contains $Distro) {
    $ver = Get-WslDistroVersion -Name $Distro
    if ($ver -ne 2) {
        Write-Info "Converting $Distro from WSL${ver} to WSL2"
        & wsl.exe --set-version $Distro 2 2>&1 | ForEach-Object { Write-Info $_ }
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Failed to convert $Distro to WSL2 (exit $LASTEXITCODE)"
        }
    }
    Write-Output "[ok] WSL distro $Distro already present"
    exit 0
}

# A different but compatible distro? Use it.
foreach ($candidate in $compatibleDistros) {
    if ($existing -contains $candidate) {
        Write-Info "Using already-installed compatible distro: $candidate"
        Write-Output "[ok] Using existing distro $candidate"
        # Re-export the chosen distro name to a sentinel file so 30/40 can
        # pick it up.
        Set-Content -Path (Join-Path $env:TEMP 'falconpulsar-distro.txt') -Value $candidate -NoNewline
        exit 0
    }
}

# Nothing compatible -- install the requested one.
Write-Info "Installing $Distro via 'wsl --install'..."
Write-Info '(this can take 5-15 minutes the first time -- downloading ~500 MB)'

# --no-launch keeps the install non-interactive (no UNIX user prompt).
& wsl.exe --install -d $Distro --no-launch 2>&1 | ForEach-Object { Write-Info $_ }
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "wsl --install -d $Distro failed (exit $LASTEXITCODE). Re-run after rebooting if you just enabled WSL."
}

# wsl --install can complete asynchronously on some Windows builds -- poll
# for the distro to actually appear. Cap at 5 minutes.
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    if (Test-WslDistroPresent -Name $Distro) { break }
    Start-Sleep -Seconds 5
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Stop-WithError "Timed out waiting for $Distro to register. Try running 'wsl --install -d $Distro' manually and re-run the installer."
}

# -- Distro health check ----------------------------------------------------
# Verify the distro actually starts and can execute a command. A corrupted
# distro (partial install, power loss during setup) will be registered but
# fail to launch.
Write-Info "Verifying $Distro can start..."
$healthCheck = & wsl.exe -d $Distro -u root -- echo ok 2>&1
if ($LASTEXITCODE -ne 0 -or "$healthCheck" -notmatch 'ok') {
    Write-Err "$Distro is registered but failed to start."
    Write-Err "Output: $healthCheck"
    Write-Err ""
    Write-Err "The distro may be corrupted. To fix:"
    Write-Err "  1. Run: wsl --unregister $Distro"
    Write-Err "  2. Re-run FalconPulsar-Setup.exe (it will install a fresh distro)"
    Stop-WithError "Distro $Distro failed health check"
}
Write-Info "$Distro is healthy"

Write-Output "[ok] WSL distro $Distro installed"
exit 0
