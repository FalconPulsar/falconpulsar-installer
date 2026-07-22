# =============================================================================
# 50-register-shortcuts.ps1 -- Create Start Menu shortcuts.
#
# Adds a "FalconPulsar" group under the All Users Start Menu with:
#
#   - Open FalconPulsar Web UI       -- http://localhost:8080
#   - Start FalconPulsar             -- wsl docker compose up -d
#   - Stop FalconPulsar              -- wsl docker compose down
#   - Restart FalconPulsar           -- wsl docker compose restart
#   - Show Status                    -- wsl docker compose ps
#   - Tail Logs                      -- wsl docker compose logs -f
#   - Open Stack Folder              -- explorer \\wsl.localhost\<distro>\<stack dir>
#   - Uninstall FalconPulsar         -- handled by Inno Setup's normal uninstall
#
# All shortcuts are .lnk files written via WScript.Shell COM. They invoke
# wsl.exe directly so they work even when the user has no Linux terminal
# emulator open.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Distro,
    [Parameter(Mandatory)] [string] $InstallDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Write-Step 'Registering Start Menu shortcuts'

# Honour the sentinel, with fallback to WSL query
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
} else {
    # No sentinel -- try to find a compatible distro
    $compatibleDistros = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu', 'Debian')
    foreach ($candidate in $compatibleDistros) {
        if (Test-WslDistroPresent -Name $candidate) {
            $Distro = $candidate
            break
        }
    }
}

# Shortcuts are cosmetic -- wrap everything in try/catch so a permission
# error or COM failure doesn't abort the entire install.
try {

# Resolve the WSL-side stack directory from the sentinel written by
# 40-run-fp-installer.ps1 (per-user installs live at /home/<user>/
# falconpulsar). Fall back to the legacy service-user path only when the
# sentinel is missing (pre-refactor installs).
$homeSentinel = Join-Path $env:TEMP 'falconpulsar-home.txt'
$stackHome = if (Test-Path $homeSentinel) { (Get-Content $homeSentinel -Raw).Trim() } else { '/home/falconpulsar' }
Write-Info "Stack directory for shortcuts: $stackHome"

$startMenu = [Environment]::GetFolderPath('CommonPrograms')
$groupDir  = Join-Path $startMenu 'FalconPulsar'
if (-not (Test-Path $groupDir)) {
    New-Item -ItemType Directory -Path $groupDir -Force | Out-Null
}

$shell = New-Object -ComObject WScript.Shell

# v0.1 has no custom .ico -- Windows uses the default Inno Setup icon for
# the .lnk and a generic browser icon for the .url. A real icon lands
# before v1.0.

function New-WslShortcut {
    param(
        [string] $Name,
        [string] $BashCommand,
        [switch] $Interactive
    )

    $linkPath = Join-Path $groupDir ("$Name.lnk")
    $sc = $shell.CreateShortcut($linkPath)
    # No -u override: run as the distro's default user (owns the stack in
    # per-user installs; legacy installs override via -u on the command line).
    if ($Interactive) {
        # Keep the console window open so the user can read the output.
        # cmd.exe /k holds the window after wsl.exe exits.
        $sc.TargetPath = "$env:WINDIR\System32\cmd.exe"
        $sc.Arguments  = "/k `"wsl.exe -d $Distro -- bash -ilc `"$BashCommand`"`""
    } else {
        $sc.TargetPath = "$env:WINDIR\System32\wsl.exe"
        $sc.Arguments = "-d $Distro -- bash -ilc `"$BashCommand`""
    }
    $sc.Description  = $Name
    # Use the falcon icon if available
    $icoPath = Join-Path $InstallDir 'assets\falcon.ico'
    if (Test-Path $icoPath) {
        $sc.IconLocation = "$icoPath,0"
    }
    $sc.Save()
    Write-Info "Created shortcut: $Name"
}

function New-UrlShortcut {
    param([string] $Name, [string] $Url)

    $linkPath = Join-Path $groupDir ("$Name.url")
    @"
[InternetShortcut]
URL=$Url
"@ | Set-Content -Path $linkPath -Encoding ASCII
    Write-Info "Created URL shortcut: $Name"
}

New-UrlShortcut -Name 'Open FalconPulsar Web UI' -Url 'http://localhost:8080'

# Relaunch the tray manager (for when the user has quit/killed it).
$trayExe = Join-Path $InstallDir 'FalconPulsarTray.exe'
if (Test-Path $trayExe) {
    $linkPath = Join-Path $groupDir 'FalconPulsar Tray Manager.lnk'
    $sc = $shell.CreateShortcut($linkPath)
    $sc.TargetPath   = $trayExe
    $sc.Description  = 'Relaunch the FalconPulsar tray manager (shows status + stack controls)'
    $icoPath = Join-Path $InstallDir 'assets\falcon.ico'
    if (Test-Path $icoPath) {
        $sc.IconLocation = "$icoPath,0"
    }
    $sc.Save()
    Write-Info 'Created shortcut: FalconPulsar Tray Manager'
}

# fp console -- opens cmd with the fp CLI ready. fp.exe is our wrapper that
# forwards to the Linux fp inside WSL, so the user sees the same TUI as a
# native Linux install without switching terminals.
$fpExe = Join-Path $env:LOCALAPPDATA 'falconpulsar\bin\fp.exe'
if (Test-Path $fpExe) {
    $linkPath = Join-Path $groupDir 'FalconPulsar Console.lnk'
    $sc = $shell.CreateShortcut($linkPath)
    $sc.TargetPath  = "$env:WINDIR\System32\cmd.exe"
    $sc.Arguments   = "/k `"$fpExe`" tui"
    $sc.Description = 'Open the FalconPulsar console (fp TUI)'
    $icoPath = Join-Path $InstallDir 'assets\falcon.ico'
    if (Test-Path $icoPath) {
        $sc.IconLocation = "$icoPath,0"
    }
    $sc.Save()
    Write-Info 'Created shortcut: FalconPulsar Console'
}

# All lifecycle shortcuts run in the stack directory (where compose.yml lives).
#
# --profile ai is legacy compose compat (pre-mandatory-gateway installs gated
# the ai-gateway behind an 'ai' profile; a no-op on current stacks). The
# optional AI Engine is opt-in and recorded as COMPOSE_PROFILES=engine in the
# stack's .env. A --profile CLI flag REPLACES .env COMPOSE_PROFILES, so
# hardcoding only '--profile ai' means 'Start' would NEVER bring up an enabled
# engine. Read COMPOSE_PROFILES from the .env at shortcut-creation time (the
# shortcuts are regenerated on every (re)install, so they track the current
# opt-in) and name every opted-in profile explicitly -- mirroring the macOS
# menu-bar app's composeProfileArgs().
$profileArgs = '--profile ai'
try {
    $rawProfiles = & wsl.exe -d $Distro -- bash -lc "grep -E '^COMPOSE_PROFILES=' '$stackHome/.env' 2>/dev/null | tail -1 | cut -d= -f2-"
    $rawProfiles = "$rawProfiles".Trim().Trim([char]0)
    foreach ($p in ($rawProfiles -split '[,\s]+')) {
        $p = $p.Trim().Trim('"').Trim("'")
        if ($p -and $p -ne 'ai') { $profileArgs += " --profile $p" }
    }
} catch {
    Write-Warn "Could not read COMPOSE_PROFILES from .env; using '$profileArgs'"
}
Write-Info "Compose profile flags for lifecycle shortcuts: $profileArgs"

New-WslShortcut -Name 'Start FalconPulsar'   -BashCommand "cd '$stackHome' && docker compose $profileArgs up -d"   -Interactive
New-WslShortcut -Name 'Stop FalconPulsar'    -BashCommand "cd '$stackHome' && docker compose $profileArgs down"    -Interactive
New-WslShortcut -Name 'Restart FalconPulsar' -BashCommand "cd '$stackHome' && docker compose $profileArgs restart" -Interactive
New-WslShortcut -Name 'Show Status'          -BashCommand "cd '$stackHome' && docker compose $profileArgs ps"      -Interactive
New-WslShortcut -Name 'Tail Logs'            -BashCommand "cd '$stackHome' && docker compose $profileArgs logs -f" -Interactive

# Open the stack folder in Explorer via the wsl.localhost UNC path.
# Note that this requires WSL2 + Win11 (or Win10 build 21354+).
$stackUnc = "\\wsl.localhost\$Distro" + ($stackHome -replace '/', '\')
$linkPath = Join-Path $groupDir 'Open Stack Folder.lnk'
$sc = $shell.CreateShortcut($linkPath)
$sc.TargetPath   = 'explorer.exe'
$sc.Arguments    = $stackUnc
$sc.Description  = 'Open the FalconPulsar stack folder in Windows Explorer'
$icoPath = Join-Path $InstallDir 'assets\falcon.ico'
if (Test-Path $icoPath) {
    $sc.IconLocation = "$icoPath,0"
}
$sc.Save()
Write-Info 'Created shortcut: Open Stack Folder'

Write-Output "[ok] Start Menu shortcuts created in $groupDir"

} catch {
    Write-Warn "Could not create all Start Menu shortcuts: $($_.Exception.Message)"
    Write-Warn 'The install succeeded -- shortcuts are cosmetic. You can access FalconPulsar at http://localhost:8080'
}
exit 0
