# =============================================================================
# 00-check-prereqs.ps1 -- Windows-side prerequisite checks.
#
# Runs first in the [Run] section. Anything fatal here aborts the install
# before any system change is made.
#
# Checks:
#   - Windows version (>= 10.0.19045)
#   - Windows edition (Home, Pro, Enterprise, Education, Server 2022/2025
#     are supported; LTSC is supported; older Server editions are not)
#   - Architecture (x64 only -- ARM64 is Phase 3)
#   - Hyper-V / virtualization extensions enabled in BIOS
#
# WSL feature presence is NOT checked here -- 10-enable-wsl.ps1 enables it
# if missing. We just need to know that the host is *capable* of running it.
# =============================================================================

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Checking Windows prerequisites'

# -- Windows version ---------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$build = [int] (($os.BuildNumber) -as [int])
Write-Info "Windows $($os.Caption) -- build $build"

if ($build -lt 19045) {
    Stop-WithError "Windows build $build is too old. Minimum: 19045 (Windows 10 22H2). See REQUIREMENTS.md."
}

# -- Edition ----------------------------------------------------------------
# WSL2 needs Pro/Enterprise/Education on Win 10 builds older than 19041.
# On 19041+ Home is fine. We've already required >= 19045 above so all
# editions work.
$edition = $os.Caption
$badEditions = @('Windows Server 2008', 'Windows Server 2012', 'Windows Server 2016', 'Windows Server 2019')
foreach ($bad in $badEditions) {
    if ($edition -like "*$bad*") {
        Stop-WithError "$edition is not supported. Minimum server: Windows Server 2022. See REQUIREMENTS.md."
    }
}
Write-Info "Edition: $edition (supported)"

# -- Architecture ------------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
    Stop-WithError "Architecture $arch is not supported. FalconPulsar requires x64. ARM64 is Phase 3."
}
Write-Info "Architecture: $arch"

# -- Hardware virtualization ------------------------------------------------
# Win32_Processor exposes VirtualizationFirmwareEnabled (BIOS-level) and
# SecondLevelAddressTranslationExtensions. WSL2 needs both.
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if (-not $cpu.VirtualizationFirmwareEnabled) {
        Stop-WithError @'
Hardware virtualization (VT-x / AMD-V) is disabled in your BIOS/UEFI.
WSL2 requires it. Reboot, enter BIOS setup, enable Intel VT-x or AMD-V
(sometimes labelled "SVM" on AMD), save, and re-run this installer.
'@
    }
    if (-not $cpu.SecondLevelAddressTranslationExtensions) {
        Stop-WithError 'Your CPU does not support SLAT (Second Level Address Translation), which WSL2 requires.'
    }
    Write-Info "CPU virtualization: enabled ($($cpu.Name))"
} catch {
    Write-Warn "Could not query CPU virtualization status: $($_.Exception.Message)"
    Write-Warn 'Continuing -- WSL2 enable will fail later if virt is not actually enabled.'
}

# -- Disk space --------------------------------------------------------------
# Need ~10 GB on the WSL distro's host drive (typically C:). The WSL distro
# itself plus all the docker images plus the time-series database easily eat
# 5 GB. Be generous.
$drive = (Get-PSDrive C)
$freeGB = [math]::Round($drive.Free / 1GB)
if ($freeGB -lt 10) {
    Stop-WithError "Insufficient free disk on C:: ${freeGB} GB free, 10 GB required."
}
Write-Info "Disk: ${freeGB} GB free on C: (min 10 GB)"

Write-Output '[ok] Windows prerequisites OK'
exit 0
