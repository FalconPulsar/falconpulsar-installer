# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# 45-verify-health.ps1 -- Verify FalconPulsar containers are running.
#
# Called after 40-run-fp-installer.ps1. Checks each container with retries
# using exit codes (not temp file parsing).
#
# Exit codes:
#   0 -- all required containers are running
#   1 -- a required container not running after retries
# =============================================================================

[CmdletBinding()]
param(
    [string] $Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Verifying FalconPulsar installation health'

# Use sentinel file if available
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
    Write-Info "Using distro from sentinel: $Distro"
} else {
    # Ask each registered distro what it IS (os-release) instead of matching
    # its WSL registration name against a hardcoded list. See
    # Test-DistroSupported in lib.ps1.
    $supported = @(Get-SupportedWslDistros)
    if ($supported.Count -gt 0) {
        $Distro = $supported[0]
        Write-Info "Found compatible distro: $Distro"
    }
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Write-Err "Distro $Distro is not registered"
    exit 1
}

# Check each container using exit codes -- no temp file parsing.
$containers = @(
    @{ Name = 'falconpulsar-core';       Label = 'Core (database + REST API)'; Required = $true },
    @{ Name = 'falconpulsar-ui';         Label = 'Web UI';                     Required = $true },
    @{ Name = 'falconpulsar-ai-gateway'; Label = 'AI Gateway';                 Required = $true }
)

$maxRetries = 6
$retryDelay = 10
$allOk = $true

foreach ($c in $containers) {
    $name = $c.Name
    $label = $c.Label
    $required = $c.Required
    $found = $false

    Write-Info "Checking $label ($name)..."

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        # Exit 0 if running, exit 1 if not. grep -q returns 0/1 cleanly.
        $checkScript = "docker ps --filter name=$name --filter status=running -q 2>/dev/null | grep -q ."
        $rc = Invoke-WslBash -Distro $Distro -Script $checkScript -User root

        if ($rc -eq 0) {
            Write-Info "  $label : RUNNING"
            $found = $true
            break
        }

        if ($attempt -lt $maxRetries) {
            Write-Info "  $label : waiting (attempt $attempt/$maxRetries, retrying in ${retryDelay}s)..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    if (-not $found) {
        if ($required) {
            Write-Err "  $label : NOT RUNNING after $maxRetries attempts"
            $allOk = $false
        } else {
            Write-Warn "  $label : not running yet (may still be starting)"
        }
    }
}

# Check Core REST API health endpoint
Write-Info 'Checking Core REST API health...'
$apiScript = 'curl -sf http://localhost:7433/api/v1/health >/dev/null 2>&1'
$apiRc = Invoke-WslBash -Distro $Distro -Script $apiScript -User root
if ($apiRc -eq 0) {
    Write-Info '  REST API: responding on port 7433'
} else {
    Write-Warn '  REST API: not responding yet (core may still be initializing)'
}

# Check Web UI
Write-Info 'Checking Web UI...'
$uiScript = 'curl -sf http://localhost:8080 >/dev/null 2>&1'
$uiRc = Invoke-WslBash -Distro $Distro -Script $uiScript -User root
if ($uiRc -eq 0) {
    Write-Info '  Web UI: responding on port 8080'
} else {
    Write-Warn '  Web UI: not responding yet (may still be starting)'
}

# Check AI Gateway health endpoint
Write-Info 'Checking AI Gateway health...'
$gwScript = 'curl -sf http://localhost:7436/health >/dev/null 2>&1'
$gwRc = Invoke-WslBash -Distro $Distro -Script $gwScript -User root
if ($gwRc -eq 0) {
    Write-Info '  AI Gateway: responding on port 7436'
} else {
    Write-Warn '  AI Gateway: not responding yet (may still be starting)'
}

# Check the two surfaces the shell embeds. A shell whose surfaces are
# unreachable still loads and still looks fine -- the Workplace and Agents
# modes are simply empty rectangles, with nothing on screen to say why. That
# is the failure this check exists to name.
Write-Info 'Checking embedded surfaces...'
# Since the single-origin fold the surfaces have no host port of their own --
# they are reached only through the shell's nginx at /copilot/ and /engine/.
foreach ($surface in @(
    @{ Label = 'AI Engine';      Path = '/engine/' },
    @{ Label = 'Command Center'; Path = '/copilot/' }
)) {
    $sScript = "curl -sf http://localhost:8080$($surface.Path) >/dev/null 2>&1"
    $sRc = Invoke-WslBash -Distro $Distro -Script $sScript -User root
    if ($sRc -eq 0) {
        Write-Info "  $($surface.Label): reachable through the shell at $($surface.Path)"
    } else {
        Write-Warn "  $($surface.Label): not reachable through the shell at $($surface.Path) -- that mode will show as unavailable"
    }
}

Write-Step 'Health check summary'
if ($allOk) {
    Write-Output ''
    Write-Output '[ok] FalconPulsar is installed and running'
    Write-Output ''
    Write-Output '  Web UI:     http://localhost:8080'
    Write-Output '  REST API:   http://localhost:7433'
    Write-Output '  WebSocket:  ws://localhost:7434'
    Write-Output '  AI Gateway: http://localhost:7436'
    Write-Output '  AI Engine:  http://localhost:8080/agents (embedded in the shell)'
    Write-Output ''
    exit 0
} else {
    Write-Err 'One or more required containers are not running.'
    Write-Err 'Check the logs manually:'
    # Read the home sentinel so we point at the right path for this install.
    $homeSentinel = Join-Path $env:TEMP 'falconpulsar-home.txt'
    $stackHome = if (Test-Path $homeSentinel) { (Get-Content $homeSentinel -Raw).Trim() } else { '/home/falconpulsar' }
    Write-Err "  wsl -d $Distro -- docker compose -f ${stackHome}/compose.yml logs"
    exit 1
}
