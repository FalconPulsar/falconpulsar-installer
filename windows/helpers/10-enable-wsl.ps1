# =============================================================================
# 10-enable-wsl.ps1 -- Enable the WSL2 Windows feature.
#
# Idempotent: if WSL is already enabled and `wsl --status` works, the script
# is a fast no-op. Otherwise it enables both required features:
#
#   - Microsoft-Windows-Subsystem-Linux
#   - VirtualMachinePlatform
#
# Then runs `wsl --update` to make sure the kernel package is current.
#
# If a reboot is required to finish enabling the features, the script writes
# a clear message to the install log and exits with code 2 to signal "reboot
# and re-run the installer". Inno Setup's installer needs to be re-launched
# manually after the reboot -- there's no native re-launch hook.
# =============================================================================

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Enabling WSL2'

if (Test-WslWorking) {
    Write-Info 'WSL is already installed and working'
    Write-Info 'Updating WSL kernel + components (best-effort)...'
    & wsl.exe --update 2>&1 | ForEach-Object { Write-Info $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "wsl --update returned exit code $LASTEXITCODE -- continuing anyway"
    }
    Write-Output '[ok] WSL is ready'
    exit 0
}

if (-not (Test-Wsl2Enabled)) {
    Write-Info 'Enabling Windows feature: Microsoft-Windows-Subsystem-Linux'
    $r1 = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -NoRestart
    Write-Info 'Enabling Windows feature: VirtualMachinePlatform'
    $r2 = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -NoRestart

    if ($r1.RestartNeeded -or $r2.RestartNeeded) {
        Write-Warn ''
        Write-Warn '================================================================'
        Write-Warn ' A REBOOT IS REQUIRED to finish enabling WSL2.'
        Write-Warn ''
        Write-Warn ' 1. Click Finish to close this installer'
        Write-Warn ' 2. Reboot Windows'
        Write-Warn ' 3. Re-run FalconPulsar-Setup.exe -- it will pick up where it'
        Write-Warn '    left off and skip the steps that are already done.'
        Write-Warn '================================================================'
        Stop-WithError 'Reboot required -- re-run the installer after restarting Windows.'
    }
}

# Features were already enabled (or just enabled and no reboot needed).
# Set WSL2 as the default version, then update the kernel.
Write-Info 'Setting WSL default version to 2'
& wsl.exe --set-default-version 2 2>&1 | ForEach-Object { Write-Info $_ }

Write-Info 'Updating WSL kernel + components'
& wsl.exe --update 2>&1 | ForEach-Object { Write-Info $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Warn "wsl --update returned exit code $LASTEXITCODE -- continuing"
}

if (-not (Test-WslWorking)) {
    Stop-WithError 'WSL features were enabled but `wsl --status` still fails. Try rebooting and re-running the installer.'
}

Write-Output '[ok] WSL2 enabled and ready'
exit 0
