# =============================================================================
# 45-verify-health.ps1 -- Verify FalconPulsar containers are running.
#
# Called after 40-run-fp-installer.ps1 to confirm the installation
# actually worked. Checks each container individually with retries
# (containers may still be starting after the compose up).
#
# Exit codes:
#   0 -- all containers healthy
#   1 -- core container not running after retries
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
    $compatibleDistros = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu', 'Debian')
    foreach ($candidate in $compatibleDistros) {
        if (Test-WslDistroPresent -Name $candidate) {
            $Distro = $candidate
            Write-Info "Found compatible distro: $Distro"
            break
        }
    }
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Write-Err "Distro $Distro is not registered"
    exit 1
}

# Check each container individually with status reporting
$containers = @(
    @{ Name = 'falconpulsar-core';       Label = 'Core (database + REST API)'; Required = $true },
    @{ Name = 'falconpulsar-ui';         Label = 'Web UI';                     Required = $false },
    @{ Name = 'falconpulsar-ai-gateway'; Label = 'AI Gateway';                 Required = $false }
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
        $checkScript = "docker ps --filter name=$name --filter status=running -q 2>/dev/null | wc -l"
        $rc = Invoke-WslBash -Distro $Distro -Script $checkScript -User root

        # Read the count from the last line of output in the log
        $countFile = Join-Path $env:TEMP 'fp-wsl-stdout.txt'
        $count = 0
        if (Test-Path $countFile) {
            $lastLine = (Get-Content $countFile -Tail 1).Trim()
            if ($lastLine -match '^\d+$') {
                $count = [int]$lastLine
            }
        }

        if ($count -ge 1) {
            # Get the container status details
            $statusScript = "docker ps --filter name=$name --format '{{.Status}}' 2>/dev/null"
            $null = Invoke-WslBash -Distro $Distro -Script $statusScript -User root
            $status = ''
            if (Test-Path $countFile) {
                $status = (Get-Content $countFile -Tail 1).Trim()
            }
            Write-Info "  $label : RUNNING ($status)"
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
$apiScript = @'
if curl -sf http://localhost:7433/api/v1/health >/dev/null 2>&1; then
    echo "ok"
else
    echo "fail"
fi
'@
$null = Invoke-WslBash -Distro $Distro -Script $apiScript -User root
$apiResult = ''
$apiFile = Join-Path $env:TEMP 'fp-wsl-stdout.txt'
if (Test-Path $apiFile) {
    $apiResult = (Get-Content $apiFile -Tail 1).Trim()
}

if ($apiResult -eq 'ok') {
    Write-Info '  REST API: responding on port 7433'
} else {
    Write-Warn '  REST API: not responding yet (core may still be initializing)'
}

# Check Web UI
Write-Info 'Checking Web UI...'
$uiScript = @'
if curl -sf http://localhost:8080 >/dev/null 2>&1; then
    echo "ok"
else
    echo "fail"
fi
'@
$null = Invoke-WslBash -Distro $Distro -Script $uiScript -User root
$uiResult = ''
if (Test-Path $apiFile) {
    $uiResult = (Get-Content $apiFile -Tail 1).Trim()
}

if ($uiResult -eq 'ok') {
    Write-Info '  Web UI: responding on port 8080'
} else {
    Write-Warn '  Web UI: not responding yet (may still be starting)'
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
    Write-Output ''
    exit 0
} else {
    Write-Err 'One or more required containers are not running.'
    Write-Err 'Check the logs manually:'
    Write-Err "  wsl -d $Distro -u falconpulsar -- docker compose -f /home/falconpulsar/compose.yml logs"
    exit 1
}
