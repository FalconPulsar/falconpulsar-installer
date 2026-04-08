# =============================================================================
# lib.ps1 — shared helpers for the FalconPulsar Windows installer scripts.
#
# Dot-sourced by every helper. Provides:
#
#   Write-Step      coloured section banner
#   Write-Info      info-level log line
#   Write-Warn      warning-level log line
#   Write-Err       error-level log line
#   Stop-WithError  print error + exit 1
#   Test-Wsl2Enabled            does the Windows host have WSL2?
#   Test-WslDistroPresent       is a given WSL distro registered?
#   Get-WslDistroVersion        WSL version (1 or 2) of a registered distro
#   Invoke-WslBash              run a bash command inside a distro safely
#   ConvertTo-WslPath           translate C:\foo\bar to /mnt/c/foo/bar
#
# All output goes to stdout/stderr — Inno Setup captures it into the install
# log file at %TEMP%\Setup Log YYYY-MM-DD #NNN.txt which the user can attach
# to a bug report. We deliberately do NOT use Write-Host with -ForegroundColor
# because Inno Setup runs PowerShell hidden and the colour escapes end up
# polluting the log.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Output ''
    Write-Output "==> $Message"
}

function Write-Info  { param([Parameter(Mandatory)] [string] $Message) Write-Output "[info] $Message" }
function Write-Warn  { param([Parameter(Mandatory)] [string] $Message) Write-Output "[warn] $Message" }
function Write-Err   { param([Parameter(Mandatory)] [string] $Message) [Console]::Error.WriteLine("[error] $Message") }

function Stop-WithError {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Err $Message
    exit 1
}

# ── Windows feature / WSL probes ────────────────────────────────────────────

# Returns $true if both required Windows features are enabled. We check
# Microsoft-Windows-Subsystem-Linux (the WSL feature itself) and
# VirtualMachinePlatform (required for WSL2).
function Test-Wsl2Enabled {
    try {
        $wsl  = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction Stop
        $vmp  = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -ErrorAction Stop
        return ($wsl.State -eq 'Enabled') -and ($vmp.State -eq 'Enabled')
    } catch {
        return $false
    }
}

# Returns $true if `wsl --status` reports a working installation.
function Test-WslWorking {
    try {
        $null = & wsl.exe --status 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ── Distro helpers ──────────────────────────────────────────────────────────

# `wsl --list --quiet` outputs UTF-16 by default. Decode + trim each line.
function Get-WslDistros {
    if (-not (Test-WslWorking)) { return @() }

    # Force unicode output to avoid the UTF-16 BOM mess.
    $output = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    return $output | ForEach-Object {
        # Strip null bytes that the UTF-16 → ASCII reinterpretation can leave.
        ($_ -replace "`0", '').Trim()
    } | Where-Object { $_ -ne '' }
}

function Test-WslDistroPresent {
    param([Parameter(Mandatory)] [string] $Name)
    return (Get-WslDistros) -contains $Name
}

# Returns 1 or 2 (WSL version), or $null if the distro isn't installed.
function Get-WslDistroVersion {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Test-WslDistroPresent -Name $Name)) { return $null }

    $output = & wsl.exe --list --verbose 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    foreach ($line in $output) {
        $clean = ($line -replace "`0", '').Trim()
        if ($clean -match "^\*?\s*$([regex]::Escape($Name))\s+\S+\s+(\d+)") {
            return [int] $matches[1]
        }
    }
    return $null
}

# ── Bash invocation ─────────────────────────────────────────────────────────

# Invoke-WslBash <distro> <bash-script-string>
#
# Runs a bash command inside the given distro as the root user (because
# WSL --user defaults to whatever user is set in /etc/wsl.conf, which is
# unreliable on first install). Captures stdout + stderr into the install
# log and propagates the exit code.
function Invoke-WslBash {
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [Parameter(Mandatory)] [string] $Script,
        [string] $User = 'root'
    )

    # `-u root` keeps us privileged for system-level operations even after
    # the falconpulsar user is created.
    & wsl.exe -d $Distro -u $User -- bash -c $Script
    return $LASTEXITCODE
}

# Translate a Windows path to its WSL mount path.
# C:\Program Files\FalconPulsar  →  /mnt/c/Program Files/FalconPulsar
function ConvertTo-WslPath {
    param([Parameter(Mandatory)] [string] $WindowsPath)

    $abs = (Resolve-Path -LiteralPath $WindowsPath -ErrorAction SilentlyContinue)
    if ($null -eq $abs) {
        # Path may not exist yet — best-effort literal conversion.
        $abs = $WindowsPath
    } else {
        $abs = $abs.Path
    }

    if ($abs -notmatch '^[A-Za-z]:[\\/]') {
        throw "Cannot convert non-absolute Windows path: $WindowsPath"
    }

    $drive = $abs.Substring(0, 1).ToLower()
    $rest  = $abs.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}
