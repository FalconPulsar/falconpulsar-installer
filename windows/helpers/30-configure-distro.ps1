# =============================================================================
# 30-configure-distro.ps1 — Configure systemd inside the WSL distro.
#
# Required because the bash installer enables a systemd user unit (in
# --mode systemd) and because Docker's official install script (which the
# bash installer calls) sets up docker.service via systemctl. Without
# `systemd=true` in /etc/wsl.conf the distro runs SysVinit-style and none
# of that works.
#
# Idempotent: skips the write if /etc/wsl.conf already declares
# `systemd=true`. Always runs `wsl --terminate` so the next bash
# invocation picks up the new init system.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step "Configuring systemd inside $Distro"

# Honour the sentinel from 20-install-distro.ps1 (in case the user already
# had a different compatible distro).
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
    Write-Info "Using distro from sentinel: $Distro"
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Stop-WithError "Distro $Distro is not registered — 20-install-distro should have run first"
}

# Quick probe: is systemd already PID 1?
$probe = & wsl.exe -d $Distro -u root -- bash -c 'ps -p 1 -o comm= 2>/dev/null' 2>$null
if ($probe -and ($probe.Trim() -eq 'systemd')) {
    Write-Output '[ok] systemd is already PID 1'
    exit 0
}

Write-Info '/etc/wsl.conf needs systemd=true'

# Append [boot] / systemd=true if not already present. heredoc-style write
# from PowerShell is awkward, so we generate the bash one-liner inline.
$wslConfScript = @'
set -e
mkdir -p /etc
if grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null; then
    echo "[info] /etc/wsl.conf already has systemd=true"
    exit 0
fi
if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
else
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
fi
echo "[info] /etc/wsl.conf updated"
'@

$rc = Invoke-WslBash -Distro $Distro -Script $wslConfScript -User root
if ($rc -ne 0) {
    Stop-WithError "Failed to update /etc/wsl.conf inside ${Distro} (exit $rc)"
}

# Force a clean shutdown so systemd takes over on next launch.
Write-Info 'Restarting the distro so systemd becomes PID 1'
& wsl.exe --terminate $Distro 2>&1 | ForEach-Object { Write-Info $_ }

# Re-launch and verify systemd is now PID 1.
$probe2 = & wsl.exe -d $Distro -u root -- bash -c 'sleep 2; ps -p 1 -o comm= 2>/dev/null' 2>$null
if (-not $probe2 -or ($probe2.Trim() -ne 'systemd')) {
    Stop-WithError "systemd is still not PID 1 inside $Distro after restart. Check /etc/wsl.conf manually."
}

Write-Output "[ok] systemd is PID 1 inside $Distro"
exit 0
