# =============================================================================
# 25-test-registry.ps1 -- Test a container registry from the Windows installer.
#
# Called by the "Test connection" button on the Container Registry wizard
# page (installer.iss -> RegistryTestClick). Runs a manifest probe against
# the provided registry inside the WSL distro, with optional credentials.
#
# Because the bash installer inside WSL is what will actually pull the
# images, we run the probe inside the distro too -- that way the test
# result reflects the exact network path the real install will take
# (host DNS, WSL network config, proxy settings, etc.).
#
# Exit codes (interpreted by RegistryTestClick in installer.iss):
#   0 -- OK, images are pullable with the given settings
#   1 -- auth required, credentials rejected or missing
#   2 -- network error, DNS failure, or registry unreachable
#   3 -- other error (distro missing, docker not available in WSL, etc.)
#
# Never blocks, never prompts. Runs in a hidden window so the user sees
# the wizard UI, not a flashing PowerShell console.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Distro,
    [Parameter(Mandatory)] [string] $Registry,
    [string] $Username = '',
    [string] $Password = '',
    [string] $Image = 'core',
    [string] $Tag = 'latest'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step "Testing container registry: $Registry/$Image`:$Tag"

# ---------------------------------------------------------------------------
# Precondition: the distro must exist. If the user clicks "Test connection"
# before the installer has reached the distro-install step, we can't run
# the probe. Fail with exit code 3 so the button label reflects that it's
# not a transient error.
# ---------------------------------------------------------------------------
if (-not (Test-WslWorking)) {
    Write-Err "WSL is not running yet. Test connection after the Ubuntu distro has been installed, or run the installer end-to-end and let it handle registry detection."
    exit 3
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Write-Err "Distro $Distro is not registered yet. Click Next to continue; the installer will probe the registry during the real install step."
    exit 3
}

# ---------------------------------------------------------------------------
# Build the bash probe script. Uses `docker manifest inspect` which does a
# HEAD-ish request without pulling layers -- fast and cheap, doesn't affect
# Docker Hub rate limits the way a full pull would.
# ---------------------------------------------------------------------------
# Escape single quotes in user-provided values for embedding in a bash
# single-quoted string. Standard pattern: replace ' with '\''.
$regEscaped = $Registry -replace "'", "'\''"
$imgEscaped = $Image -replace "'", "'\''"
$tagEscaped = $Tag -replace "'", "'\''"

# If credentials were provided, log in first. The password is piped via
# stdin (--password-stdin), never passed on the command line.
$loginBlock = ''
if ($Username -ne '' -and $Password -ne '') {
    $userEscaped = $Username -replace "'", "'\''"
    $passEscaped = $Password -replace "'", "'\''"
    # Extract hostname from "ghcr.io/falconpulsar" -> "ghcr.io"
    $loginBlock = @"
REG_HOST=`$(printf '%s' '$regEscaped' | awk -F/ '{print `$1}')
if ! printf '%s' '$passEscaped' | docker login "`$REG_HOST" --username '$userEscaped' --password-stdin >/dev/null 2>&1; then
    echo "[error] docker login rejected"
    exit 1
fi
echo "[info] docker login OK"
"@
}

$probeScript = @"
set -e
# Functional check (docker info), not `command -v docker`: with Docker Desktop
# installed but its WSL integration OFF, a docker SHIM is on PATH -- command -v
# would find it and we'd fall through to a confusing "docker login rejected".
if ! docker info >/dev/null 2>&1; then
    echo "[error] docker is not usable inside the distro yet (if Docker Desktop is installed, enable its WSL integration for this distro)"
    exit 3
fi
$loginBlock
REF='$regEscaped/$imgEscaped:$tagEscaped'
if ERR=`$(DOCKER_CLI_HINTS=false docker manifest inspect "`$REF" 2>&1 >/dev/null); then
    echo "[ok] `$REF is pullable"
    exit 0
fi
case "`$ERR" in
    *unauthorized*|*"authentication required"*|*"pull access denied"*|*"requested access to the resource is denied"*)
        echo "[error] auth required: `$ERR"
        exit 1
        ;;
    *"no such host"*|*"dial tcp"*|*"TLS handshake timeout"*|*"connection refused"*)
        echo "[error] network: `$ERR"
        exit 2
        ;;
    *"manifest unknown"*|*"not found"*|*NAME_UNKNOWN*|*MANIFEST_UNKNOWN*)
        echo "[error] image not found: `$ERR"
        exit 2
        ;;
    *toomanyrequests*|*"rate limit"*)
        echo "[error] rate limited: `$ERR"
        exit 2
        ;;
    *)
        echo "[error] other: `$ERR"
        exit 2
        ;;
esac
"@

Write-Info "Running probe inside $Distro ..."
$rc = Invoke-WslBash -Distro $Distro -Script $probeScript -User root

switch ($rc) {
    0 {
        Write-Output "[ok] registry $Registry is reachable and $Image`:$Tag is pullable"
    }
    1 {
        Write-Err "authentication required or rejected for $Registry"
    }
    2 {
        Write-Err "network / other error probing $Registry"
    }
    3 {
        Write-Err "docker is not available inside $Distro (test cannot run yet)"
    }
    default {
        Write-Err "unexpected exit code $rc from probe"
        $rc = 2
    }
}

exit $rc
