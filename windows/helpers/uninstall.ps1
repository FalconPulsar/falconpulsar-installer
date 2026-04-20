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
# NOTE: lib.ps1 sets $ErrorActionPreference = 'Stop' in the caller's
# scope (dot-source semantics). Anything that throws past this line
# -- including assignment to a read-only automatic variable like $HOME
# -- is a TERMINATING error and will halt the script unless caught.

# Global trap so any unhandled exception writes its cause to the install
# log before we die. Without this, a silent halt (the $home-shadowing
# bug that caused docker cleanup to no-op, for example) leaves the user
# with a log that just stops mid-sentence and no way to tell why.
# Mirror of the trap pattern in 40-run-fp-installer.ps1.
trap {
    $msg   = $_.Exception.Message
    $where = $_.InvocationInfo.PositionMessage
    $stack = $_.ScriptStackTrace
    try {
        Write-FpLogLine ''
        Write-FpLogLine "[fatal] uninstall.ps1 crashed: $msg"
        Write-FpLogLine "[fatal] At: $where"
        Write-FpLogLine "[fatal] Stack:"
        Write-FpLogLine $stack
    } catch { }
    try {
        [Console]::Error.WriteLine("[fatal] uninstall.ps1 crashed: $msg")
        [Console]::Error.WriteLine("[fatal] At: $where")
        [Console]::Error.WriteLine("[fatal] Stack:")
        [Console]::Error.WriteLine($stack)
    } catch { }
    exit 1
}

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
#
# The script executes as root (Invoke-WslBash -User root) and runs docker
# commands directly -- root has access to docker.sock on both Docker
# Desktop WSL integration AND native Docker Engine installs. The earlier
# implementation sudo-switched to the stack owner for this; that was
# fragile (relied on group membership propagating through sudo + sg docker)
# and swallowed every error via 2>/dev/null, so cleanup would no-op
# silently when sudo/sg failed. Running as root avoids both issues.
Write-Info 'Stopping FalconPulsar containers and removing stack files...'
$purgeFlag = if ($Purge) { '1' } else { '0' }
# IMPORTANT: do NOT name this loop variable $home -- that is a PowerShell
# automatic variable (Constant in Windows PowerShell 5.1) and foreach
# assignment to it silently throws "Cannot overwrite variable HOME
# because it is read-only or constant." With $ErrorActionPreference =
# 'Continue' the script then skips the entire foreach body, so no docker
# cleanup runs and the user sees containers/images/volumes still present
# after uninstall. Use $stackHome instead.
foreach ($stackHome in $WslHomes) {
    Write-Info ("  -> cleanup pass: {0}" -f $stackHome)
    $cleanupScript = @"
set +e
HOME_DIR='$stackHome'
PURGE=$purgeFlag
echo "[info] === cleanup pass: `$HOME_DIR (purge=`$PURGE) ==="

if ! command -v docker >/dev/null 2>&1; then
    echo '[info] docker not installed in distro -- skipping container/image cleanup'
else
    COMPOSE_FLAGS='--profile ai down --remove-orphans'
    [ "`$PURGE" = "1" ] && COMPOSE_FLAGS="`$COMPOSE_FLAGS --volumes"

    if [ -f "`$HOME_DIR/compose.yml" ]; then
        echo "[info] docker compose `$COMPOSE_FLAGS (in `$HOME_DIR)"
        ( cd "`$HOME_DIR" && docker compose `$COMPOSE_FLAGS ) 2>&1 | sed 's/^/[compose] /'

        # Harvest compose-referenced images -- removes images from
        # non-default registries too (not just falconpulsar/*).
        IMAGES=`$( cd "`$HOME_DIR" && docker compose config --images 2>/dev/null | sort -u )
        if [ -n "`$IMAGES" ]; then
            echo "[info] removing compose-referenced images:"
            echo "`$IMAGES" | sed 's/^/[img]  /'
            echo "`$IMAGES" | while IFS= read -r img; do
                [ -n "`$img" ] && docker rmi -f "`$img" 2>&1 | sed 's/^/[rmi] /'
            done
        fi
    fi

    # Sweep any orphan falconpulsar-* containers not tied to compose
    # (e.g. left behind by an aborted prior run).
    ORPHANS=`$(docker ps -a --filter 'name=falconpulsar-' --format '{{.Names}}' 2>/dev/null)
    if [ -n "`$ORPHANS" ]; then
        echo "[info] removing orphan containers:"
        echo "`$ORPHANS" | sed 's/^/[ps]   /'
        echo "`$ORPHANS" | while IFS= read -r name; do
            [ -n "`$name" ] && docker rm -f "`$name" 2>&1 | sed 's/^/[rm]  /'
        done
    fi

    # Generic falconpulsar/* image cleanup (covers images not referenced
    # by the current compose.yml -- stale tags from prior versions).
    MATCHES=`$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^falconpulsar/')
    if [ -n "`$MATCHES" ]; then
        echo "[info] removing falconpulsar/* images:"
        echo "`$MATCHES" | sed 's/^/[img]  /'
        echo "`$MATCHES" | while IFS= read -r img; do
            [ -n "`$img" ] && docker rmi -f "`$img" 2>&1 | sed 's/^/[rmi] /'
        done
    fi
    # Also catch reference='*falconpulsar*' (custom registries)
    EXTRA=`$(docker images --filter 'reference=*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)
    if [ -n "`$EXTRA" ]; then
        echo "`$EXTRA" | while IFS= read -r img; do
            [ -n "`$img" ] && docker rmi -f "`$img" 2>&1 | sed 's/^/[rmi] /'
        done
    fi

    if [ "`$PURGE" = "1" ]; then
        VOLS=`$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar')
        if [ -n "`$VOLS" ]; then
            echo "[info] removing falconpulsar volumes:"
            echo "`$VOLS" | sed 's/^/[vol]  /'
            echo "`$VOLS" | while IFS= read -r vol; do
                [ -n "`$vol" ] && docker volume rm -f "`$vol" 2>&1 | sed 's/^/[volrm] /'
            done
        fi
        # Network created by compose
        docker network rm falconpulsar 2>&1 | sed 's/^/[net] /' || true
    fi
fi

# Remove stack files in this home (but NOT the data dir unless -Purge;
# -Purge deletes the whole home in Step 3 below).
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

# One-way migration cleanup: strip ANY stale HKCU\Environment\Path entry
# pointing at a falconpulsar folder. Older installer builds (up to the
# WindowsApps refactor) used a [Registry] directive that APPENDED an entry
# on every install and never removed it on uninstall, so users who
# reinstalled N times accumulated N copies. Current builds don't write
# this key at all -- fp.exe lives in %LOCALAPPDATA%\Microsoft\WindowsApps\
# which Windows already has on PATH by default. This block exists solely
# to clean up what the OLD installer left behind; after one uninstall
# cycle, the HKCU key is clean and stays clean.
try {
    $envKey = 'HKCU:\Environment'
    $cur = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction Stop).Path
    if ($cur) {
        $parts = $cur -split ';' | Where-Object {
            $_ -ne '' -and $_ -notmatch '(?i)\\falconpulsar(\\|$)'
        }
        $new = ($parts -join ';')
        if ($new -ne $cur) {
            # -Type ExpandString keeps REG_EXPAND_SZ semantics; using
            # Set-ItemProperty with a different type would change the
            # registry value kind and surprise other apps reading PATH.
            Set-ItemProperty -Path $envKey -Name Path -Value $new -Type ExpandString
            Write-Info 'Cleaned falconpulsar entries from HKCU Environment Path'
            # Broadcast WM_SETTINGCHANGE so new shells pick it up immediately.
            $sig = @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            Add-Type -Namespace FP -Name NativeMethods -MemberDefinition $sig -ErrorAction SilentlyContinue
            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $result = [UIntPtr]::Zero
            [void][FP.NativeMethods]::SendMessageTimeout(
                $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment',
                2, 5000, [ref]$result)
        }
    }
} catch {
    Write-Warn "Could not clean HKCU PATH: $($_.Exception.Message)"
}

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
if (Test-Path $Script:FpLogPath) {
    Write-Output "  Install log: $Script:FpLogPath"
    # Open the log in Notepad so the user sees what happened even if the
    # Inno Setup window closed first. Belt-and-suspenders:
    #   1. Full path to notepad.exe (not PATH-dependent)
    #   2. -WindowStyle Normal so it isn't inherited hidden from the
    #      parent when the uninstaller was launched via /SILENT
    #   3. Print the path above FIRST, so even if Notepad fails to
    #      launch (policy block, corp lockdown, etc.) the user still
    #      knows exactly where to find the file.
    $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    if (Test-Path $notepad) {
        try {
            Start-Process -FilePath $notepad `
                          -ArgumentList ('"{0}"' -f $Script:FpLogPath) `
                          -WindowStyle Normal -ErrorAction Stop
        } catch {
            Write-Output ('  (could not auto-open Notepad: {0})' -f $_.Exception.Message)
        }
    } else {
        Write-Output '  (notepad.exe not found at its standard location; open the log manually)'
    }
} else {
    Write-Output "  (install log not found at $Script:FpLogPath)"
}
exit 0
