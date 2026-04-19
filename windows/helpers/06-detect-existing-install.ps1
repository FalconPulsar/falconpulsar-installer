# =============================================================================
# 06-detect-existing-install.ps1 -- Probe Windows + WSL state for any prior
# FalconPulsar install (successful, failed, partial, or zombie).
#
# This is the Windows equivalent of
#   macos/installer-app/.../InstallerState.swift:detectExistingInstall
# which is the gold standard. We check:
#
#   Windows-side:
#     - Inno Setup uninstall registry keys
#     - %USERPROFILE%\falconpulsar\.env mirror
#     - %LOCALAPPDATA%\falconpulsar\bin\fp.exe
#     - HKCU\...\Run\FalconPulsar auto-start entry
#     - C:\Program Files\FalconPulsar directory
#
#   WSL-side (inside the selected distro, using Docker Desktop's daemon):
#     Probes the per-user stack dir /home/<default-user>/falconpulsar
#     AND the legacy /home/falconpulsar path. Reports the first that has a
#     compose.yml (or falls through to whichever directory exists).
#     - compose.yml + .env + data/ + total size
#     - docker ps -a --filter name=falconpulsar- (containers, all + running)
#     - docker images --filter reference='*falconpulsar*'
#     - docker network ls | grep falconpulsar
#     - docker volume ls | grep falconpulsar
#
# Output format: simple KEY=VALUE lines to a sentinel file. Inno Setup's
# Pascal script parses it and populates the ExistingInstall wizard page.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Distro = '',
    [string] $OutPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ([string]::IsNullOrEmpty($OutPath)) {
    $OutPath = Join-Path $env:TEMP 'falconpulsar-existing.txt'
}

# Resolve distro: explicit arg > sentinel > wsl -l -q best match
if ([string]::IsNullOrEmpty($Distro)) {
    $sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
    if (Test-Path $sentinel) {
        $Distro = (Get-Content $sentinel -Raw).Trim()
    }
}
if ([string]::IsNullOrEmpty($Distro)) {
    try {
        $listRaw = & wsl.exe -l -q 2>$null
        $list = ($listRaw -join "`n") -replace "`0", '' -replace "`r", ''
        $names = $list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        foreach ($cand in @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu', 'Debian')) {
            foreach ($n in $names) {
                if ($n -ieq $cand) { $Distro = $n; break }
            }
            if ($Distro) { break }
        }
        if (-not $Distro -and $names.Count -ge 1) {
            # No preferred match -- take first entry
            $Distro = $names[0]
        }
    } catch {
        $Distro = ''
    }
}

$r = [ordered]@{}
$r['Distro'] = $Distro

# --- Windows-side checks ----------------------------------------------------

$innoKey1 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{{D1F8E2A3-5B7C-4F9D-B2E1-8A3C6D9F1234}}_is1'
$innoKey2 = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{{D1F8E2A3-5B7C-4F9D-B2E1-8A3C6D9F1234}}_is1'
$r['InnoKey'] = if ((Test-Path $innoKey1) -or (Test-Path $innoKey2)) { 'yes' } else { 'no' }

$winHome = Join-Path $env:USERPROFILE 'falconpulsar'
$r['WinHome']       = if (Test-Path $winHome) { 'yes' } else { 'no' }
$r['WinEnv']        = if (Test-Path (Join-Path $winHome '.env')) { 'yes' } else { 'no' }
$r['FpExe']         = if (Test-Path (Join-Path $env:LOCALAPPDATA 'falconpulsar\bin\fp.exe')) { 'yes' } else { 'no' }
$r['ProgFiles']     = if (Test-Path 'C:\Program Files\FalconPulsar') { 'yes' } else { 'no' }

try {
    $runKey = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
                               -Name 'FalconPulsar' -ErrorAction Stop
    $r['RunKey'] = 'yes'
} catch {
    $r['RunKey'] = 'no'
}

# --- WSL-side checks (best-effort; all fields default to 'no'/'0') ----------

$r['WslHome']          = 'no'
$r['WslHomeSize']      = ''
$r['WslCompose']       = 'no'
$r['WslEnv']           = 'no'
$r['WslData']          = 'no'
$r['WslDataSize']      = ''
$r['Containers']       = '0'
$r['ContainersRun']    = '0'
$r['ContainerList']    = ''
$r['Images']           = '0'
$r['ImageList']        = ''
$r['Networks']         = '0'
$r['Volumes']          = '0'

if (-not [string]::IsNullOrEmpty($Distro)) {
    try { $null = & wsl.exe -d $Distro -u root -- true 2>$null } catch { }

    if ($LASTEXITCODE -eq 0) {
        # Resolve the distro's default user so we can probe BOTH the new
        # per-user stack dir (/home/<user>/falconpulsar) AND the legacy
        # service-user dir (/home/falconpulsar). Either counts as "exists".
        $wslUser = & wsl.exe -d $Distro -- whoami 2>$null
        $wslUser = "$wslUser".Trim().Trim([char]0)
        if ([string]::IsNullOrEmpty($wslUser) -or $wslUser -eq 'root') {
            $wslUser = & wsl.exe -d $Distro -u root -- bash -c "getent passwd 1000 2>/dev/null | cut -d: -f1" 2>$null
            $wslUser = "$wslUser".Trim().Trim([char]0)
        }
        $r['WslUser'] = $wslUser
        $userHome = if ($wslUser -and $wslUser -ne 'root') { "/home/$wslUser/falconpulsar" } else { '' }
        $r['WslHomePath'] = $userHome
        $probe = @"
set +e
_out() { printf '%s\n' "`$1"; }
USER_HOME='$userHome'
# Pick whichever stack dir exists (user's > legacy). Both get checked.
if [ -n "`$USER_HOME" ] && [ -f "`$USER_HOME/compose.yml" ]; then
    HOME_DIR="`$USER_HOME"
elif [ -f /home/falconpulsar/compose.yml ]; then
    HOME_DIR=/home/falconpulsar
elif [ -n "`$USER_HOME" ] && [ -d "`$USER_HOME" ]; then
    HOME_DIR="`$USER_HOME"
elif [ -d /home/falconpulsar ]; then
    HOME_DIR=/home/falconpulsar
else
    HOME_DIR=''
fi
_out "WslHomeDir=`$HOME_DIR"

if [ -n "`$HOME_DIR" ]; then
    [ -d "`$HOME_DIR" ]               && _out 'WslHome=yes'       || _out 'WslHome=no'
    [ -f "`$HOME_DIR/compose.yml" ]   && _out 'WslCompose=yes'    || _out 'WslCompose=no'
    [ -f "`$HOME_DIR/.env" ]          && _out 'WslEnv=yes'        || _out 'WslEnv=no'
    [ -d "`$HOME_DIR/data" ]          && _out 'WslData=yes'       || _out 'WslData=no'
    if [ -d "`$HOME_DIR" ]; then
        _out "WslHomeSize=`$(du -sh "`$HOME_DIR" 2>/dev/null | awk '{print `$1}')"
    fi
    if [ -d "`$HOME_DIR/data" ]; then
        _out "WslDataSize=`$(du -sh "`$HOME_DIR/data" 2>/dev/null | awk '{print `$1}')"
    fi
else
    _out 'WslHome=no'
    _out 'WslCompose=no'
    _out 'WslEnv=no'
    _out 'WslData=no'
fi

if command -v docker >/dev/null 2>&1; then
    CN=`$(docker ps -a --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null)
    RN=`$(docker ps    --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null)
    IM=`$(docker images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
    NE=`$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar`$' | wc -l | tr -d ' ')
    VO=`$(docker volume  ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar'  | wc -l | tr -d ' ')

    _out "Containers=`$(printf '%s\n' "`$CN" | grep -c . | tr -d ' ')"
    _out "ContainersRun=`$(printf '%s\n' "`$RN" | grep -c . | tr -d ' ')"
    _out "ContainerList=`$(printf '%s' "`$CN" | tr '\n' ';' )"
    _out "Images=`$(printf '%s\n' "`$IM" | grep -c . | tr -d ' ')"
    _out "ImageList=`$(printf '%s' "`$IM" | tr '\n' ';' )"
    _out "Networks=`$NE"
    _out "Volumes=`$VO"
fi
"@
        try {
            $lines = & wsl.exe -d $Distro -u root -- bash -c $probe 2>$null
            foreach ($line in $lines) {
                if ($line -match '^([A-Za-z]+)=(.*)$') {
                    $r[$matches[1]] = $matches[2]
                }
            }
        } catch {
            Write-Warn "WSL probe failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "Cannot reach distro '$Distro' for WSL-side probe"
    }
}

# --- Derived flag: is there ANY prior install evidence? --------------------

$any = ($r['InnoKey']       -eq 'yes') -or
       ($r['WinEnv']        -eq 'yes') -or
       ($r['FpExe']         -eq 'yes') -or
       ($r['ProgFiles']     -eq 'yes') -or
       ($r['RunKey']        -eq 'yes') -or
       ($r['WslCompose']    -eq 'yes') -or
       ($r['WslEnv']        -eq 'yes') -or
       ($r['WslData']       -eq 'yes') -or
       ([int]($r['Containers']) -gt 0) -or
       ([int]($r['Images'])     -gt 0) -or
       ([int]($r['Networks'])   -gt 0) -or
       ([int]($r['Volumes'])    -gt 0)
$r['HasPrior'] = if ($any) { 'yes' } else { 'no' }

# --- Write sentinel ---------------------------------------------------------

$out = foreach ($k in $r.Keys) { "$k=$($r[$k])" }
Set-Content -Path $OutPath -Value $out -Encoding ASCII
Write-Info "Existing-install sentinel written: $OutPath (HasPrior=$($r['HasPrior']))"
exit 0
