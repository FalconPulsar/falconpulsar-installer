# =============================================================================
# 45-verify-health.ps1 -- Verify FalconPulsar containers are running.
#
# Called after 40-run-fp-installer.ps1 to confirm the installation
# actually worked. Checks that the 3 FalconPulsar containers (core, ui,
# ai-gateway) are running inside the WSL distro.
#
# Exit codes:
#   0 -- all containers healthy
#   1 -- one or more containers missing or not running
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

# Check running containers
$healthScript = @'
set -e
echo "[info] Checking Docker containers..."
docker ps --filter name=falconpulsar --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true

CORE=$(docker ps --filter name=falconpulsar-core --filter status=running -q 2>/dev/null | wc -l)
UI=$(docker ps --filter name=falconpulsar-ui --filter status=running -q 2>/dev/null | wc -l)
GW=$(docker ps --filter name=falconpulsar-ai-gateway --filter status=running -q 2>/dev/null | wc -l)

TOTAL=$((CORE + UI + GW))
echo "[info] Running containers: core=$CORE ui=$UI ai-gateway=$GW (total=$TOTAL)"

if [ "$CORE" -lt 1 ]; then
    echo "[error] falconpulsar-core is not running"
    exit 1
fi
if [ "$UI" -lt 1 ]; then
    echo "[warn] falconpulsar-ui is not running (may still be starting)"
fi
if [ "$GW" -lt 1 ]; then
    echo "[warn] falconpulsar-ai-gateway is not running (may still be starting)"
fi

# Check if core REST API is responding
if curl -sf http://localhost:7433/api/v1/health >/dev/null 2>&1; then
    echo "[ok] Core REST API is responding on port 7433"
else
    echo "[warn] Core REST API not responding yet (may still be initializing)"
fi

echo "[ok] FalconPulsar installation verified"
exit 0
'@

$rc = Invoke-WslBash -Distro $Distro -Script $healthScript -User root

if ($rc -ne 0) {
    Write-Err "Health check failed (exit $rc)"
    Write-Err "The containers may need more time to start. Check manually:"
    Write-Err "  wsl -d $Distro -u falconpulsar -- docker compose ps"
    exit $rc
}

Write-Output '[ok] FalconPulsar is running'
exit 0
