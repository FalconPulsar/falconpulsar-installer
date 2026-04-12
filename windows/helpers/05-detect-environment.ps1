# =============================================================================
# 05-detect-environment.ps1 -- Detect WSL, distros, Docker Desktop state.
#
# Runs BEFORE wizard pages are shown (called from InitializeSetup). Writes
# a simple key=value file to %TEMP%\falconpulsar-detect.txt that the Inno
# Setup Pascal Script reads to configure the wizard (distro selection page,
# conditional helper execution, Test Connection plumbing).
#
# Output format (one key=value per line, no quoting):
#
#   WSL_STATUS=working|not-installed|features-missing
#   DOCKER_DESKTOP=running|installed|not-found
#   DISTRO_COUNT=N
#   DISTRO_1_NAME=Ubuntu-24.04
#   DISTRO_1_WSLVER=2
#   DISTRO_1_DOCKER=yes|no
#   DISTRO_1_COMPATIBLE=yes|no|unknown
#   DISTRO_1_OS_INFO=Ubuntu 24.04 LTS
#   ...
#
# Compatible distros: Ubuntu 22.04+, Debian 12+, RHEL/Rocky/Alma 9+,
# Fedora 41+, openSUSE Leap 15.6+.
#
# Exit codes:
#   0 -- detection completed (even if WSL is missing)
#   1 -- unexpected error
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# We dot-source lib.ps1 for Write-Info etc., but detection must not fail
# if lib.ps1 is missing (this helper might run before files are extracted
# in some edge cases). Guard with Test-Path.
$libPath = Join-Path $PSScriptRoot 'lib.ps1'
if (Test-Path $libPath) {
    . $libPath
} else {
    function Write-Info  { param([string]$Message) Write-Output "[info] $Message" }
    function Write-Warn  { param([string]$Message) Write-Output "[warn] $Message" }
    function Write-Err   { param([string]$Message) [Console]::Error.WriteLine("[error] $Message") }
    function Write-Step  { param([string]$Message) Write-Output ""; Write-Output "==> $Message" }
}

Write-Step 'Detecting environment'

$outPath = Join-Path $env:TEMP 'falconpulsar-detect.txt'
$results = @{}

# ---------------------------------------------------------------------------
# 1. WSL status
# ---------------------------------------------------------------------------
$wslStatus = 'not-installed'
try {
    $null = & wsl.exe --status 2>$null
    if ($LASTEXITCODE -eq 0) {
        $wslStatus = 'working'
    } else {
        # WSL binary exists but features may not be enabled
        $wslStatus = 'features-missing'
    }
} catch {
    # wsl.exe not found at all
    $wslStatus = 'not-installed'
}
$results['WSL_STATUS'] = $wslStatus
Write-Info "WSL status: $wslStatus"

# ---------------------------------------------------------------------------
# 2. Docker Desktop
# ---------------------------------------------------------------------------
$dockerDesktop = 'not-found'
if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
    $dockerDesktop = 'running'
} elseif (Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe") {
    $dockerDesktop = 'installed'
}
$results['DOCKER_DESKTOP'] = $dockerDesktop
Write-Info "Docker Desktop: $dockerDesktop"

# ---------------------------------------------------------------------------
# 3. Enumerate WSL distros
# ---------------------------------------------------------------------------
$distros = @()

if ($wslStatus -eq 'working') {
    try {
        $rawList = & wsl.exe --list --quiet 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawList) {
            $distros = $rawList | ForEach-Object {
                ($_ -replace "`0", '').Trim()
            } | Where-Object {
                # Filter out Docker Desktop's internal WSL distros --
                # they are management VMs, not real Linux environments.
                $_ -ne '' -and
                $_ -ne 'docker-desktop' -and
                $_ -ne 'docker-desktop-data'
            }
        }
    } catch {
        # Ignore
    }
}

$distroCount = @($distros).Count
$results['DISTRO_COUNT'] = $distroCount
Write-Info "Distros found: $distroCount"

# ---------------------------------------------------------------------------
# 4. For each distro: WSL version, Docker availability, OS compatibility
# ---------------------------------------------------------------------------

# Compatible OS detection: read /etc/os-release inside the distro and
# check ID + VERSION_ID against the supported list.
$compatibleOsList = @{
    'ubuntu'    = [version]'22.04'
    'debian'    = [version]'12.0'
    'rhel'      = [version]'9.0'
    'rocky'     = [version]'9.0'
    'almalinux' = [version]'9.0'
    'fedora'    = [version]'41.0'
    'opensuse-leap' = [version]'15.6'
}

for ($i = 0; $i -lt $distroCount; $i++) {
    $name = @($distros)[$i]
    $idx = $i + 1
    $results["DISTRO_${idx}_NAME"] = $name

    Write-Info "  [$idx] $name"

    # WSL version (1 or 2)
    $wslVer = '0'
    try {
        $verboseList = & wsl.exe --list --verbose 2>$null
        if ($LASTEXITCODE -eq 0 -and $verboseList) {
            foreach ($line in $verboseList) {
                $clean = ($line -replace "`0", '').Trim()
                if ($clean -match "^\*?\s*$([regex]::Escape($name))\s+\S+\s+(\d+)") {
                    $wslVer = $matches[1]
                    break
                }
            }
        }
    } catch {}
    $results["DISTRO_${idx}_WSLVER"] = $wslVer
    Write-Info "      WSL version: $wslVer"

    # Docker available?
    $hasDocker = 'no'
    try {
        $dockerCheck = & wsl.exe -d $name -u root -- bash -c 'command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && echo yes || echo no' 2>$null
        if ($dockerCheck) {
            $hasDocker = ($dockerCheck -replace "`0", '').Trim()
        }
    } catch {}
    $results["DISTRO_${idx}_DOCKER"] = $hasDocker
    Write-Info "      Docker: $hasDocker"

    # OS info + compatibility
    $osInfo = 'unknown'
    $compatible = 'unknown'
    try {
        $osRelease = & wsl.exe -d $name -u root -- bash -c 'cat /etc/os-release 2>/dev/null' 2>$null
        if ($LASTEXITCODE -eq 0 -and $osRelease) {
            $osId = ''
            $osVersionId = ''
            $prettyName = ''
            foreach ($line in $osRelease) {
                $clean = ($line -replace "`0", '').Trim()
                if ($clean -match '^ID=(.+)$') {
                    $osId = $matches[1].Trim('"', "'")
                }
                if ($clean -match '^VERSION_ID=(.+)$') {
                    $osVersionId = $matches[1].Trim('"', "'")
                }
                if ($clean -match '^PRETTY_NAME=(.+)$') {
                    $prettyName = $matches[1].Trim('"', "'")
                }
            }

            if ($prettyName) { $osInfo = $prettyName }

            # Check compatibility
            if ($osId -and $osVersionId) {
                $osIdLower = $osId.ToLower()
                if ($compatibleOsList.ContainsKey($osIdLower)) {
                    $minVer = $compatibleOsList[$osIdLower]
                    try {
                        # Handle version strings like "24.04" or "12"
                        $actualVer = [version]($osVersionId -replace '[^0-9.]', '')
                        if ($actualVer -ge $minVer) {
                            $compatible = 'yes'
                        } else {
                            $compatible = 'no'
                        }
                    } catch {
                        $compatible = 'unknown'
                    }
                } else {
                    $compatible = 'no'
                }
            }
        }
    } catch {}
    $results["DISTRO_${idx}_OS_INFO"] = $osInfo
    $results["DISTRO_${idx}_COMPATIBLE"] = $compatible
    Write-Info "      OS: $osInfo"
    Write-Info "      Compatible: $compatible"
}

# ---------------------------------------------------------------------------
# 5. Write results
# ---------------------------------------------------------------------------
$lines = @()
foreach ($key in ($results.Keys | Sort-Object)) {
    $lines += "$key=$($results[$key])"
}
$lines | Set-Content -Path $outPath -Encoding UTF8

Write-Info "Detection results written to $outPath"
Write-Output "[ok] Environment detection complete"
exit 0
