# =============================================================================
# uninstall.ps1 -- Called by Inno Setup's CurUninstallStepChanged.
#
# Two modes:
#
#   Default (no -Purge):
#     - Stop and remove Docker containers
#     - Remove compose.yml and .env
#     - Remove staged installer files at /opt/falconpulsar-installer
#     - Remove Start Menu shortcuts
#     - KEEP /home/falconpulsar/data (database preserved)
#     - KEEP the falconpulsar user
#     - KEEP the WSL distro
#
#   With -Purge:
#     - Everything above, plus:
#     - Delete /home/falconpulsar entirely (database, config, all data)
#     - Remove the falconpulsar system user
#     - Remove Docker images
#
# Never removes:
#   - The WSL distro itself (it may host other things)
#   - Docker Engine (other projects may use it)
#   - The WSL Windows feature
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Distro,
    [switch] $Purge,
    [switch] $Force
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Uninstalling FalconPulsar from WSL'

# Honour the sentinel
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Write-Warn "Distro $Distro is not registered -- nothing to uninstall on the WSL side"
    exit 0
}

# Admin authentication gate — require the FalconPulsar admin password before
# any destructive action. -Force bypasses for emergencies (broken Core).
if ($Force) {
    Write-Warn '-Force supplied: skipping admin authentication'
} else {
    $authed = Assert-AdminAuth `
        -Title 'Uninstall FalconPulsar' `
        -Message 'Enter admin credentials to authorize uninstallation. This prevents accidental removal of the stack.'
    if (-not $authed) {
        Write-Warn 'Uninstallation cancelled by user (or admin authentication failed).'
        exit 1
    }
}

# Write a run marker so the user can read a single audit trail of install + uninstall.
$modeTag = if ($Purge) { 'purge' } else { 'keep' }
Write-FpLogLine ''
Write-FpLogLine ("=== {0:O}  uninstall (platform=windows, pid={1}, mode={2}) ===" -f (Get-Date).ToUniversalTime(), $PID, $modeTag)

if ($Purge) {
    Write-Info 'Mode: FULL REMOVAL (containers + data + user)'
} else {
    Write-Info 'Mode: keep data (containers removed, database preserved)'
}

# Step 1: Stop and remove containers (+ volumes if purging)
Write-Info 'Stopping FalconPulsar containers...'
$purgeFlag = if ($Purge) { '1' } else { '0' }
$stopScript = @"
set +e
PURGE=$purgeFlag
if command -v docker >/dev/null 2>&1; then
    if [ -f /home/falconpulsar/compose.yml ]; then
        cd /home/falconpulsar
        if [ "`$PURGE" = "1" ]; then
            sudo -u falconpulsar -H sg docker -c "docker compose down --remove-orphans --volumes" 2>/dev/null
            echo "[info] Containers and named volumes removed"
        else
            sudo -u falconpulsar -H sg docker -c "docker compose down --remove-orphans" 2>/dev/null
            echo "[info] Containers stopped and removed (volumes preserved)"
        fi
    else
        echo "[info] No compose.yml found -- skipping container stop"
    fi
else
    echo "[info] Docker not available -- skipping container stop"
fi
"@
$null = Invoke-WslBash -Distro $Distro -Script $stopScript -User root
Write-Info 'Containers stopped'

# Step 2: Remove Docker images + stack files (+ orphan volumes on purge)
Write-Info 'Removing Docker images and stack files...'
$cleanScript = @"
set +e
PURGE=$purgeFlag
if command -v docker >/dev/null 2>&1; then
    # Harvest images referenced by compose.yml first (catches custom registries)
    if [ -f /home/falconpulsar/compose.yml ]; then
        IMAGES="`$(cd /home/falconpulsar && sudo -u falconpulsar -H sg docker -c 'docker compose config --images' 2>/dev/null | sort -u)"
        if [ -n "`$IMAGES" ]; then
            echo "`$IMAGES" | xargs -r sudo -u falconpulsar -H sg docker -c 'docker rmi -f `"`$@`"' _ 2>/dev/null
        fi
    fi
    # Fallback to known names (older installs)
    sudo -u falconpulsar -H sg docker -c "docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^falconpulsar/' | xargs -r docker rmi -f" 2>/dev/null
    # Orphan volumes on purge
    if [ "`$PURGE" = "1" ]; then
        sudo -u falconpulsar -H sg docker -c "docker volume ls --format '{{.Name}}' | grep -E '^falconpulsar' | xargs -r docker volume rm -f" 2>/dev/null
    fi
    echo "[info] Docker images removed"
fi
rm -f /home/falconpulsar/compose.yml 2>/dev/null
rm -f /home/falconpulsar/.env 2>/dev/null
rm -rf /opt/falconpulsar-installer 2>/dev/null
echo "[info] Stack files removed"
"@
$null = Invoke-WslBash -Distro $Distro -Script $cleanScript -User root
Write-Info 'Stack files removed'

# Step 3: If purge, remove everything
if ($Purge) {
    Write-Info 'Removing all data, database, and user...'
    $purgeScript = @'
set +e
# Remove the home directory (contains database)
rm -rf /home/falconpulsar 2>/dev/null
echo "[info] /home/falconpulsar removed (database deleted)"
# Remove the system user
# Remove systemd unit before removing user
rm -f /home/falconpulsar/.config/systemd/user/falconpulsar.service 2>/dev/null
loginctl disable-linger falconpulsar 2>/dev/null
# Remove the system user (--force to handle lingering processes)
if id falconpulsar >/dev/null 2>&1; then
    userdel --force falconpulsar 2>/dev/null
    echo "[info] falconpulsar user removed"
fi
echo "[info] Purge complete"
'@
    $null = Invoke-WslBash -Distro $Distro -Script $purgeScript -User root
    Write-Info 'Full purge complete'
} else {
    Write-Info 'Data preserved at /home/falconpulsar/data'
    Write-Info "To access: wsl -d $Distro -u root -- ls /home/falconpulsar/data"
}

# Step 4: Remove Start Menu shortcuts
$startMenu = [Environment]::GetFolderPath('CommonPrograms')
$groupDir  = Join-Path $startMenu 'FalconPulsar'
if (Test-Path $groupDir) {
    Remove-Item -Path $groupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "Removed Start Menu group: $groupDir"
}

# Sentinel cleanup
Remove-Item -Path $sentinel -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '[ok] Uninstall complete'
if (-not $Purge) {
    Write-Output '  Your database is preserved at /home/falconpulsar/data'
    Write-Output '  Reinstall FalconPulsar to resume using your existing data.'
}

# Close the run marker and surface the install log so the user has the
# complete record (installation → uninstallation) in one place.
Write-FpLogLine '=== end ==='
Write-Output ''
Write-Output "  Full log: $Script:FpLogPath"
# Open the log in Notepad so the user can read it immediately.
if (Test-Path $Script:FpLogPath) {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList $Script:FpLogPath -ErrorAction SilentlyContinue } catch { }
}
exit 0
