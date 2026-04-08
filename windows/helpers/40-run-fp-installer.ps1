# =============================================================================
# 40-run-fp-installer.ps1 — Run the bundled bash installer inside WSL.
#
# This is where Windows hands off to the Linux installer. We:
#
#   1. Resolve the WSL mount path of the install dir (C:\Program Files\
#      FalconPulsar → /mnt/c/Program Files/FalconPulsar)
#   2. Copy the linux/ + shared/ trees from the Windows-side install dir
#      into /opt/falconpulsar-installer inside the distro (the live /mnt/c
#      mount has 9p performance issues and the bash installer creates
#      symlinks + 0600 files that don't survive on the NTFS layer)
#   3. Verify Docker Hub credentials are present in the distro (the bash
#      installer's check_dockerhub_login will catch this too, but we want
#      to fail fast with a clearer error if not)
#   4. Invoke /opt/falconpulsar-installer/linux/install.sh with --mode
#      docker --yes, passing the admin credentials via a temp env file
#      (NOT the command line — argv is visible in /proc/<pid>/cmdline to
#      anyone on the machine)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Distro,
    [Parameter(Mandatory)] [string] $InstallDir,
    [Parameter(Mandatory)] [string] $AdminUser,
    [Parameter(Mandatory)] [string] $AdminPass
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Running the FalconPulsar bash installer inside WSL'

# Honour the sentinel from 20-install-distro.ps1.
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Stop-WithError "Distro $Distro is not registered"
}

if ($AdminPass.Length -lt 10) {
    Stop-WithError 'Admin password is shorter than 10 characters (the credentials page should have caught this)'
}

# ── 1. Translate the Windows install dir to a /mnt/c/... path ───────────────
$wslInstallDir = ConvertTo-WslPath -WindowsPath $InstallDir
Write-Info "Windows install dir: $InstallDir"
Write-Info "WSL mount path:      $wslInstallDir"

# ── 2. Stage installer files into /opt/falconpulsar-installer ───────────────
# Quoting the path for bash — this is the only injection vector here, and
# the install dir is always under %PROGRAMFILES% which we control.
$wslInstallDirEscaped = $wslInstallDir -replace "'", "'\''"

$stageScript = @"
set -e
rm -rf /opt/falconpulsar-installer
mkdir -p /opt/falconpulsar-installer
cp -a '$wslInstallDirEscaped/linux'  /opt/falconpulsar-installer/
cp -a '$wslInstallDirEscaped/shared' /opt/falconpulsar-installer/
chmod +x /opt/falconpulsar-installer/linux/install.sh
chmod +x /opt/falconpulsar-installer/linux/uninstall.sh
chmod +x /opt/falconpulsar-installer/shared/lib/*.sh
echo '[info] installer staged at /opt/falconpulsar-installer'
"@
$rc = Invoke-WslBash -Distro $Distro -Script $stageScript -User root
if ($rc -ne 0) {
    Stop-WithError "Failed to stage installer files (exit $rc)"
}

# ── 3. Docker Hub credentials check ─────────────────────────────────────────
# The bash installer's check_dockerhub_login will catch missing credentials,
# but we want a clearer Windows-flavoured message. The user needs to have
# already done `wsl -d Ubuntu-24.04 -- docker login` *or* there needs to
# be a config.json at /root/.docker/config.json. For first-time users this
# will fail — and that's fine, the bash installer's error message tells
# them what to do.
#
# We do NOT prompt for Docker Hub credentials in the GUI for v0.1 — that's
# a security/UX rabbit hole (storing creds, MFA, sso). Documented in
# README-windows-build.md.
Write-Info '(Docker Hub login will be verified by the bash installer)'

# ── 4. Generate a one-shot env file with the admin password and source it ──
# We never put the password on the command line. Instead we write a 0600
# file to /root/falconpulsar-install.env, source it, run install.sh, and
# delete the file in the same `bash -c` invocation. The file lives only in
# the distro's tmpfs-mounted /root for a few seconds during install.
#
# Single-quote escaping: bash single-quoted strings can't contain '. We
# replace each ' in the password with '\'' (close, escape, reopen).
$pwEscaped   = $AdminPass -replace "'", "'\''"
$userEscaped = $AdminUser -replace "'", "'\''"

$runScript = @"
set -e
umask 077
ENVFILE=`$(mktemp /root/fp-install.env.XXXXXX)
trap 'rm -f "`$ENVFILE"' EXIT
cat > "`$ENVFILE" <<'__FP_ENV_EOF__'
export FP_ADMIN_USER='$userEscaped'
export FP_ADMIN_PASS='$pwEscaped'
export FP_ASSUME_YES=1
__FP_ENV_EOF__
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

Write-Output '[ok] FalconPulsar installed inside WSL'
exit 0
