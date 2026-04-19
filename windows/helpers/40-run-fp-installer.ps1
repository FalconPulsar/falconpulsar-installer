# =============================================================================
# 40-run-fp-installer.ps1 -- Run the bundled bash installer inside WSL.
#
# This is where Windows hands off to the Linux installer. We:
#
#   1. Resolve the WSL mount path of the install dir (C:\Program Files\
#      FalconPulsar -> /mnt/c/Program Files/FalconPulsar)
#   2. Copy the linux/ + shared/ trees from the Windows-side install dir
#      into /opt/falconpulsar-installer inside the distro (the live /mnt/c
#      mount has 9p performance issues and the bash installer creates
#      symlinks + 0600 files that don't survive on the NTFS layer)
#   3. Verify Docker Hub credentials are present in the distro (the bash
#      installer's check_dockerhub_login will catch this too, but we want
#      to fail fast with a clearer error if not)
#   4. Invoke /opt/falconpulsar-installer/linux/install.sh with --mode
#      docker --yes, passing the admin credentials via a temp env file
#      (NOT the command line -- argv is visible in /proc/<pid>/cmdline to
#      anyone on the machine)
# =============================================================================

[CmdletBinding()]
param(
    # Mandatory removed so a missing-arg crash is catchable by our trap +
    # surfaced via Write-FpLogLine instead of PowerShell's interactive
    # prompt that hangs/fails silently inside Inno Setup's SW_HIDE shell.
    [string] $Distro = '',
    [string] $InstallDir = '',
    [string] $AdminUser = '',
    [string] $AdminPass = '',
    [string] $Registry = 'falconpulsar',
    [string] $RegistryUser = '',
    [string] $RegistryPass = '',
    [switch] $RegistrySkip,
    [string] $AIGateway = 'false',
    [string] $InstallAction = ''
)

$ErrorActionPreference = 'Stop'

# Trap MUST be installed before lib.ps1 dot-source -- if lib.ps1 itself
# has a parse error or a dependency miss, this is the only way to find
# out (PowerShell exits 1 silently otherwise). Direct file write because
# Write-FpLogLine isn't defined yet at this point.
$Script:EarlyLogPath = Join-Path $env:TEMP 'falconpulsar-install.log'
trap {
    $msg = $_.Exception.Message
    $where = $_.InvocationInfo.PositionMessage
    $stack = $_.ScriptStackTrace
    $line = "`n[error] 40-run-fp-installer.ps1 crashed: $msg`n[error] At: $where`n[error] Stack:`n$stack`n"
    try {
        Add-Content -Path $Script:EarlyLogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
    exit 1
}

# Heartbeat -- direct write before lib.ps1 is loaded.
try {
    Add-Content -Path $Script:EarlyLogPath -Value "`n==> 40-run-fp-installer.ps1 entered (PSVersion=$($PSVersionTable.PSVersion), Distro='$Distro', InstallDir='$InstallDir', AdminUser='$AdminUser')" -ErrorAction SilentlyContinue
} catch { }

. (Join-Path $PSScriptRoot 'lib.ps1')

# Manually validate the params we used to mark Mandatory.
foreach ($pair in @(
    @{Name='Distro';      Value=$Distro},
    @{Name='InstallDir';  Value=$InstallDir},
    @{Name='AdminUser';   Value=$AdminUser},
    @{Name='AdminPass';   Value=$AdminPass}
)) {
    if ([string]::IsNullOrEmpty($pair.Value)) {
        Stop-WithError "Required parameter -$($pair.Name) was not provided (got empty string)."
    }
}

Write-Step 'Running the FalconPulsar bash installer inside WSL'

# -- Sentinel: pick the right distro name -----------------------------------
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
    Write-Info "Using distro from sentinel: $Distro"
} else {
    # No sentinel -- query WSL for a compatible distro
    Write-Info "No sentinel file -- checking for compatible WSL distros"
    $compatibleDistros = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu', 'Debian')
    $found = $false
    foreach ($candidate in $compatibleDistros) {
        if (Test-WslDistroPresent -Name $candidate) {
            $Distro = $candidate
            $found = $true
            Write-Info "Found compatible distro: $Distro"
            break
        }
    }
    if (-not $found) {
        Stop-WithError "No compatible WSL distro found and no sentinel file. Run the installer from the beginning."
    }
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Stop-WithError "Distro $Distro is not registered"
}

# -- WSL root access check --------------------------------------------------
# Verify we can run commands as root inside the distro. If the distro's
# default user is non-root and something overrides -u root, the bash
# installer will fail deep inside with confusing permission errors.
Write-Info "Verifying root access inside $Distro..."
$whoami = & wsl.exe -d $Distro -u root -- whoami 2>&1
if ($LASTEXITCODE -ne 0 -or "$whoami".Trim() -ne 'root') {
    Stop-WithError "Cannot run as root inside $Distro (got: $whoami). The distro may be corrupted -- try: wsl --unregister $Distro and re-run the installer."
}
Write-Info "Root access verified"

if ($AdminPass.Length -lt 10) {
    Stop-WithError 'Admin password is shorter than 10 characters (the credentials page should have caught this)'
}

# -- 1. Translate the Windows install dir to a /mnt/c/... path ---------------
$wslInstallDir = ConvertTo-WslPath -WindowsPath $InstallDir
Write-Info "Windows install dir: $InstallDir"
Write-Info "WSL mount path:      $wslInstallDir"

# -- 2. Stage installer files into /opt/falconpulsar-installer ---------------
$wslInstallDirEscaped = $wslInstallDir -replace "'", "'\''"

$stageScript = @"
set -e
rm -rf /opt/falconpulsar-installer
mkdir -p /opt/falconpulsar-installer
cp -a '$wslInstallDirEscaped/linux'  /opt/falconpulsar-installer/
cp -a '$wslInstallDirEscaped/shared' /opt/falconpulsar-installer/
# Strip Windows CRLF line endings from all text config files. The files
# were copied from NTFS (/mnt/c/) where Git (autocrlf) or Inno Setup may
# have converted them to CRLF. Bash chokes on \r in scripts, and the
# Python YAML loader in the ai-gateway container raises a ReaderError
# when it hits a stray \r in gateway.yaml -- the container exits 1 and
# `docker ps` shows a crash-loop. Strip CRLF from everything text-ish.
find /opt/falconpulsar-installer \
    \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \
       -o -name '*.env' -o -name '*.conf' -o -name '*.template' \
       -o -name 'Dockerfile' \) \
    -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x /opt/falconpulsar-installer/linux/install.sh
chmod +x /opt/falconpulsar-installer/linux/uninstall.sh
chmod +x /opt/falconpulsar-installer/shared/lib/*.sh
echo '[info] installer staged at /opt/falconpulsar-installer'
"@
$rc = Invoke-WslBash -Distro $Distro -Script $stageScript -User root
if ($rc -ne 0) {
    Stop-WithError "Failed to stage installer files (exit $rc)"
}

# -- 3. Check for existing FalconPulsar installation -------------------------
# If the data directory already has a config file, this is a re-install /
# upgrade. Skip the admin password prompt and just bring the stack up.
# Detect existing install inside WSL
$existingInstall = & wsl.exe -d $Distro -u root -- bash -c 'test -f /home/falconpulsar/data/falconpulsar.toml && echo yes || echo no' 2>$null
$hasExisting = ($existingInstall -and $existingInstall.Trim() -eq 'yes')

# If Inno Setup already determined the action, use it; otherwise default
# based on whether an existing install was found.
if (-not $InstallAction) {
    if ($hasExisting) { $InstallAction = 'upgrade' }
    else              { $InstallAction = 'fresh' }
}
Write-Info "Install action: $InstallAction"

if ($InstallAction -eq 'upgrade' -and $hasExisting) {
    Write-Info 'Upgrading in place -- pulling latest images and restarting'
    $profileFlag = if ($AIGateway -eq 'true') { '--profile ai' } else { '' }
    $upgradeScript = @"
set -e
export FP_ASSUME_YES=1
export FP_LEGAL_ACCEPTED=1
cd /home/falconpulsar 2>/dev/null || cd /opt/falconpulsar-installer
if [ -f /home/falconpulsar/compose.yml ]; then
    sudo -u falconpulsar -H sg docker -c "cd /home/falconpulsar && docker compose $profileFlag pull && docker compose $profileFlag up -d"
    echo '[ok] Stack upgraded and restarted'
else
    echo '[info] No existing compose.yml found -- running full installer'
    FP_INSTALL_ACTION=upgrade FP_AI_GATEWAY_ENABLED=$AIGateway bash /opt/falconpulsar-installer/linux/install.sh --mode docker --yes
fi
"@
    $rc = Invoke-WslBash -Distro $Distro -Script $upgradeScript -User root
    if ($rc -ne 0) {
        Stop-WithError "Upgrade failed inside WSL with exit code $rc."
    }
    Write-Output '[ok] FalconPulsar upgraded inside WSL'
    exit 0
}

# For 'fresh' -- clean up WSL-side data before running the full installer
if ($InstallAction -eq 'fresh' -and $hasExisting) {
    Write-Info 'Fresh install -- removing existing data inside WSL'
    $cleanScript = @"
set +e
cd /home/falconpulsar 2>/dev/null && sudo -u falconpulsar -H sg docker -c 'docker compose down --remove-orphans --volumes' 2>/dev/null
rm -rf /home/falconpulsar
echo '[ok] Previous install cleaned'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $cleanScript -User root
}

# -- 4. Docker Desktop detection ---------------------------------------------
$dockerDesktopRunning = $false
if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
    $dockerDesktopRunning = $true
    Write-Info 'Docker Desktop detected on host'
}

$dockerInDistro = & wsl.exe -d $Distro -u root -- bash -c 'command -v docker >/dev/null 2>&1 && echo yes || echo no' 2>$null
$dockerAvailable = $false
if ($dockerInDistro) {
    $dockerAvailable = ($dockerInDistro.Trim() -eq 'yes')
}

if ($dockerDesktopRunning -and -not $dockerAvailable) {
    Stop-WithError @"
Docker Desktop is running on your Windows host, but its WSL Integration is
NOT enabled for the $Distro distro. The bash installer needs docker
to be available inside the distro.

To fix this:
  1. Open Docker Desktop
  2. Go to Settings -> Resources -> WSL Integration
  3. Toggle ON the integration for "$Distro"
  4. Click "Apply & Restart"
  5. Re-run FalconPulsar-Setup.exe

Alternatively, quit Docker Desktop entirely -- the FalconPulsar installer
will then install Docker Engine directly inside the distro via the
official get.docker.com script.
"@
}

# -- 5. Docker daemon verification -------------------------------------------
# If docker is installed but the daemon is not running (e.g. systemd just
# started), try to start it before handing off to the bash installer.
if ($dockerAvailable) {
    Write-Info "Checking if Docker daemon is responsive inside $Distro..."
    $dockerInfo = & wsl.exe -d $Distro -u root -- bash -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>$null
    if ($dockerInfo -and $dockerInfo.Trim() -eq 'fail') {
        Write-Info 'Docker is installed but daemon is not running -- starting it...'
        & wsl.exe -d $Distro -u root -- bash -c 'sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true' 2>$null
        Start-Sleep -Seconds 3
        $dockerInfo2 = & wsl.exe -d $Distro -u root -- bash -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>$null
        if ($dockerInfo2 -and $dockerInfo2.Trim() -eq 'ok') {
            Write-Info 'Docker daemon started successfully'
        } else {
            Write-Warn 'Could not start Docker daemon -- the bash installer will try again'
        }
    } else {
        Write-Info 'Docker daemon is responsive'
    }
} else {
    Write-Info 'Docker not present in distro yet -- bash installer will install via get.docker.com'
}

# -- 6. Docker Hub credentials check -----------------------------------------
Write-Info '(Docker Hub login will be verified by the bash installer)'

# -- 7. Run the bash installer -----------------------------------------------
# Generate a one-shot env file with the admin password inside the distro.
# The password never appears on the command line (argv is visible in
# /proc/<pid>/cmdline). The file is deleted in the same bash invocation.
$pwEscaped   = $AdminPass -replace "'", "'\''"
$userEscaped = $AdminUser -replace "'", "'\''"
$regEscaped  = $Registry -replace "'", "'\''"
$regUserEscaped = $RegistryUser -replace "'", "'\''"
$regPassEscaped = $RegistryPass -replace "'", "'\''"
$regSkipVal = if ($RegistrySkip) { '1' } else { '0' }

$runScript = @"
set -e
umask 077
ENVFILE=`$(mktemp /root/fp-install.env.XXXXXX)
trap 'rm -f "`$ENVFILE"' EXIT
printf '%s\n' \
  "export FP_ADMIN_USER='$userEscaped'" \
  "export FP_ADMIN_PASS='$pwEscaped'" \
  "export FP_ASSUME_YES=1" \
  "export FP_LEGAL_ACCEPTED=1" \
  "export FP_REGISTRY='$regEscaped'" \
  "export FP_REGISTRY_USER='$regUserEscaped'" \
  "export FP_REGISTRY_PASS='$regPassEscaped'" \
  "export FP_REGISTRY_SKIP='$regSkipVal'" \
  "export FP_INSTALL_ACTION='$InstallAction'" \
  "export FP_AI_GATEWAY_ENABLED='$AIGateway'" \
  > "`$ENVFILE"
. "`$ENVFILE"
rm -f "`$ENVFILE"
trap - EXIT
bash /opt/falconpulsar-installer/linux/install.sh --mode docker --yes
"@

Write-Info 'Invoking bash installer (this can take 5-10 minutes for image pulls + first-run init)'
$rc = Invoke-WslBash -Distro $Distro -Script $runScript -User root
if ($rc -ne 0) {
    Stop-WithError "Bash installer failed inside WSL with exit code $rc. Run 'wsl -d $Distro -u root -- bash /opt/falconpulsar-installer/linux/install.sh --mode docker' manually to see the full output."
}

# Mirror the AI flag to the Windows side so the tray + fp.exe can read it
# (they can't access the WSL filesystem directly).
$winEnvDir = Join-Path $env:USERPROFILE 'falconpulsar'
if (-not (Test-Path $winEnvDir)) { New-Item -ItemType Directory -Path $winEnvDir -Force | Out-Null }
$winEnvPath = Join-Path $winEnvDir '.env'
Set-Content -Path $winEnvPath -Value "FP_AI_GATEWAY_ENABLED=$AIGateway"
Write-Info "Mirrored AI flag to $winEnvPath"

# Stage the Linux fp binary into WSL so the Windows fp.exe wrapper has
# something to exec. The wrapper does:
#   wsl.exe -d <distro> -u falconpulsar --cd /home/falconpulsar -e /home/falconpulsar/bin/fp <args>
$fpLinuxSrc = Join-Path $InstallDir 'fp-linux-amd64'
if (Test-Path $fpLinuxSrc) {
    $fpLinuxInWsl = ConvertTo-WslPath -WindowsPath $fpLinuxSrc
    $stageFpScript = @"
set -e
install -d -m 0755 -o falconpulsar -g falconpulsar /home/falconpulsar/bin
install -m 0755 -o falconpulsar -g falconpulsar '$fpLinuxInWsl' /home/falconpulsar/bin/fp
echo '[ok] Linux fp binary installed at /home/falconpulsar/bin/fp'
"@
    $null = Invoke-WslBash -Distro $Distro -Script $stageFpScript -User root
} else {
    Write-Warn "Linux fp binary not found at $fpLinuxSrc -- fp.exe wrapper will error until fp is installed in WSL."
}

# Write the sentinel so fp.exe (and the tray) can auto-discover the distro
# without guessing.
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
Set-Content -Path $sentinel -Value $Distro -Encoding ASCII
Write-Info "Wrote distro sentinel: $sentinel"

Write-Output '[ok] FalconPulsar installed inside WSL'
exit 0
