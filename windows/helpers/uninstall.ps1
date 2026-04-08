# =============================================================================
# uninstall.ps1 — Called by Inno Setup's [UninstallRun] section.
#
# Removes the WSL-side install:
#
#   1. Stops the docker stack inside the distro
#   2. Calls the bash uninstaller (with --purge if the user confirmed)
#   3. Removes the staged installer files at /opt/falconpulsar-installer
#
# Does NOT:
#
#   - Remove the WSL distro itself (it may be hosting other things)
#   - Disable the WSL Windows feature
#   - Delete the user's data directory by default — they have to opt in
#     via the Inno Setup uninstall confirmation dialog (which is shown by
#     Inno Setup itself, not us)
#
# The Inno Setup uninstaller deletes the Windows-side files (assets,
# helpers, bundled bash scripts) on its own after this script returns.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Distro
)

$ErrorActionPreference = 'Continue'   # uninstall must be best-effort
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Uninstalling FalconPulsar from WSL'

# Honour the sentinel.
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
}

if (-not (Test-WslDistroPresent -Name $Distro)) {
    Write-Warn "Distro $Distro is not registered — nothing to uninstall on the WSL side"
    exit 0
}

# Best-effort: run the bash uninstaller. We don't pass --purge so the
# user's data directory survives. They can wipe it manually with
# `wsl -d <distro> -u root -- rm -rf /home/falconpulsar` if they really
# want to.
$uninstallScript = @'
set +e
if [ -x /opt/falconpulsar-installer/linux/uninstall.sh ]; then
    bash /opt/falconpulsar-installer/linux/uninstall.sh --yes
elif command -v docker >/dev/null 2>&1 && [ -f /home/falconpulsar/compose.yml ]; then
    sudo -u falconpulsar -H sg docker -c "cd /home/falconpulsar && docker compose down --remove-orphans"
fi
rm -rf /opt/falconpulsar-installer
echo "[info] WSL-side uninstall complete (data preserved at /home/falconpulsar)"
'@

$rc = Invoke-WslBash -Distro $Distro -Script $uninstallScript -User root
if ($rc -ne 0) {
    Write-Warn "Bash uninstaller returned non-zero ($rc) — Windows-side files will still be removed"
}

# Clean up the Start Menu shortcuts (Inno Setup [Files] only deletes files
# it placed itself, not the .lnk files we wrote in 50-register-shortcuts).
$startMenu = [Environment]::GetFolderPath('CommonPrograms')
$groupDir  = Join-Path $startMenu 'FalconPulsar'
if (Test-Path $groupDir) {
    Remove-Item -Path $groupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "Removed Start Menu group: $groupDir"
}

# Sentinel file cleanup
Remove-Item -Path $sentinel -Force -ErrorAction SilentlyContinue

Write-Output '[ok] Uninstall complete'
exit 0
