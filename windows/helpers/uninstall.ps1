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

# Resolve the WSL-side stack directory. Per-user installs live under
# /home/<user>/falconpulsar; legacy service-user installs under
# /home/falconpulsar. We try sentinels first (cheap + exact), then probe
# the distro for the default user, then fall back to the legacy path.
$WslHome = ''
$homeSentinel = Join-Path $env:TEMP 'falconpulsar-home.txt'
if (Test-Path $homeSentinel) {
    $WslHome = (Get-Content $homeSentinel -Raw).Trim()
}
if ([string]::IsNullOrEmpty($WslHome)) {
    $WslUser = & wsl.exe -d $Distro -- whoami 2>$null
    $WslUser = "$WslUser".Trim().Trim([char]0)
    if ([string]::IsNullOrEmpty($WslUser) -or $WslUser -eq 'root') {
        $WslUser = & wsl.exe -d $Distro -u root -- bash -c "getent passwd 1000 2>/dev/null | cut -d: -f1" 2>$null
        $WslUser = "$WslUser".Trim().Trim([char]0)
    }
    if (-not [string]::IsNullOrEmpty($WslUser) -and $WslUser -ne 'root') {
        $WslHome = "/home/$WslUser/falconpulsar"
    }
}
# If we STILL don't have it, the legacy path is our only option.
$WslHomes = @()
if ($WslHome) { $WslHomes += $WslHome }
$WslHomes += '/home/falconpulsar'
$WslHomes = $WslHomes | Select-Object -Unique
Write-Info ("Uninstall target paths: {0}" -f ($WslHomes -join ', '))

# Admin authentication gate -- require the FalconPulsar admin password before
# any destructive action. -Force bypasses for emergencies (broken Core).
if ($Force) {
    Write-Warn '-Force supplied: skipping admin authentication'
} else {
    # -AllowBypassIfCoreDown: if Core isn't running, Assert-AdminAuth will
    # show a YES-confirmation dialog instead of failing outright. Matches
    # the bash uninstaller's behaviour on macOS/Linux.
    $authed = Assert-AdminAuth `
        -Title 'Uninstall FalconPulsar' `
        -Message 'Enter admin credentials to authorize uninstallation. This prevents accidental removal of the stack.' `
        -AllowBypassIfCoreDown
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

# Step 1+2: Stop containers, remove images + stack files, across every
# candidate home directory (new per-user + legacy). Running the same
# cleanup against both is idempotent and catches mixed-state systems.
Write-Info 'Stopping FalconPulsar containers and removing stack files...'
$purgeFlag = if ($Purge) { '1' } else { '0' }
foreach ($home in $WslHomes) {
    Write-Info ("  -> cleanup pass: {0}" -f $home)
    $cleanupScript = @"
set +e
HOME_DIR='$home'
PURGE=$purgeFlag
if command -v docker >/dev/null 2>&1; then
    # Determine the owner of the stack dir so we can run docker as them
    # (per-user = the human; legacy = the falconpulsar system user).
    OWNER=`$(stat -c '%U' "`$HOME_DIR" 2>/dev/null)
    [ -z "`$OWNER" ] && OWNER=root
    COMPOSE="docker compose --profile ai down --remove-orphans"
    [ "`$PURGE" = "1" ] && COMPOSE="`$COMPOSE --volumes"
    if [ -f "`$HOME_DIR/compose.yml" ]; then
        if [ "`$OWNER" = "root" ] || [ "`$OWNER" = "`$(id -un)" ]; then
            ( cd "`$HOME_DIR" && sg docker -c "`$COMPOSE" ) 2>/dev/null
        else
            ( cd "`$HOME_DIR" && sudo -u "`$OWNER" -H sg docker -c "`$COMPOSE" ) 2>/dev/null
        fi
        # Harvest compose-referenced images + generic falconpulsar/* tags.
        IMAGES=`$( cd "`$HOME_DIR" && sudo -u "`$OWNER" -H sg docker -c 'docker compose config --images' 2>/dev/null | sort -u )
        if [ -n "`$IMAGES" ]; then
            echo "`$IMAGES" | while IFS= read -r img; do
                [ -n "`$img" ] && docker rmi -f "`$img" >/dev/null 2>&1
            done
        fi
    fi
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
        grep -E '^falconpulsar/' | while IFS= read -r img; do
        [ -n "`$img" ] && docker rmi -f "`$img" >/dev/null 2>&1
    done
    if [ "`$PURGE" = "1" ]; then
        docker volume ls --format '{{.Name}}' 2>/dev/null | \
            grep -E '^falconpulsar' | while IFS= read -r vol; do
            [ -n "`$vol" ] && docker volume rm -f "`$vol" >/dev/null 2>&1
        done
    fi
fi
# Remove stack files in this home (but NOT the data dir unless -Purge).
rm -f "`$HOME_DIR/compose.yml" "`$HOME_DIR/.env" "`$HOME_DIR/gateway.yaml" 2>/dev/null
echo "[info] cleaned `$HOME_DIR"
"@
    $null = Invoke-WslBash -Distro $Distro -Script $cleanupScript -User root
}
# Staged installer tree in /opt/falconpulsar-installer is always gone.
$null = Invoke-WslBash -Distro $Distro -Script 'rm -rf /opt/falconpulsar-installer 2>/dev/null; echo [info] staged installer removed' -User root
Write-Info 'Stack files removed'

# Step 3: If purge, remove the stack home dir(s) + the legacy system user.
if ($Purge) {
    Write-Info 'Removing all data, database, and per-user stack state...'
    $homeList = ($WslHomes | ForEach-Object { "'$_'" }) -join ' '
    $purgeScript = @"
set +e
for H in $homeList; do
    rm -rf "`$H" 2>/dev/null && echo "[info] `$H removed"
done
# Legacy service-user cleanup: kill linger, remove systemd unit, userdel.
loginctl disable-linger falconpulsar 2>/dev/null
if id falconpulsar >/dev/null 2>&1; then
    userdel --force falconpulsar 2>/dev/null
    echo '[info] falconpulsar system user removed'
fi
# System-wide PATH snippet (installed by per-user mode).
rm -f /etc/profile.d/falconpulsar.sh 2>/dev/null
echo '[info] Purge complete'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $purgeScript -User root
    Write-Info 'Full purge complete'
} else {
    $firstHome = $WslHomes | Select-Object -First 1
    Write-Info ("Data preserved at {0}/data" -f $firstHome)
    Write-Info ("To access: wsl -d {0} -- ls '{1}/data'" -f $Distro, $firstHome)
}

# Step 4: Remove Start Menu shortcuts (always -- they're broken if the
# compose files are gone).
$startMenu = [Environment]::GetFolderPath('CommonPrograms')
$groupDir  = Join-Path $startMenu 'FalconPulsar'
if (Test-Path $groupDir) {
    Remove-Item -Path $groupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "Removed Start Menu group: $groupDir"
}

# Step 4b (purge only): wipe the Windows-side mirror files, auto-start key,
# the fp.exe cache, and the WindowsApps copy of fp.exe. Without this,
# "Remove all" leaves the tray from autostart and the .env mirror / fp.exe
# sitting in the user profile. Inno Setup normally auto-removes the
# WindowsApps copy via its [Files] tracking, but this defensive pass
# catches the case where someone purged via this script directly.
if ($Purge) {
    $winHome = Join-Path $env:USERPROFILE 'falconpulsar'
    if (Test-Path $winHome) {
        Remove-Item -Path $winHome -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Removed Windows-side mirror: $winHome"
    }
    $localApp = Join-Path $env:LOCALAPPDATA 'falconpulsar'
    if (Test-Path $localApp) {
        Remove-Item -Path $localApp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Removed fp.exe cache: $localApp"
    }
    $windowsAppsFp = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\fp.exe'
    if (Test-Path $windowsAppsFp) {
        Remove-Item -Path $windowsAppsFp -Force -ErrorAction SilentlyContinue
        Write-Info "Removed WindowsApps fp.exe: $windowsAppsFp"
    }
    $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if (Get-ItemProperty -Path $runKey -Name 'FalconPulsar' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name 'FalconPulsar' -ErrorAction SilentlyContinue
        Write-Info 'Removed HKCU Run auto-start entry: FalconPulsar'
    }
}

# Sentinel cleanup -- remove the distro + home + user sentinels so a
# subsequent reinstall re-detects everything from scratch.
Remove-Item -Path $sentinel -Force -ErrorAction SilentlyContinue
Remove-Item -Path $homeSentinel -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $env:TEMP 'falconpulsar-user.txt') -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '[ok] Uninstall complete'
if (-not $Purge) {
    $firstHome = $WslHomes | Select-Object -First 1
    Write-Output ('  Your database is preserved at {0}/data' -f $firstHome)
    Write-Output '  Reinstall FalconPulsar to resume using your existing data.'
}

# Close the run marker and surface the install log so the user has the
# complete record (installation -> uninstallation) in one place.
Write-FpLogLine '=== end ==='
Write-Output ''
Write-Output "  Full log: $Script:FpLogPath"
# Open the log in Notepad so the user can read it immediately.
if (Test-Path $Script:FpLogPath) {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList $Script:FpLogPath -ErrorAction SilentlyContinue } catch { }
}
exit 0
