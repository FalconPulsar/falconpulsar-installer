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
#   - Open Stack Folder              -- explorer \\wsl.localhost\<distro>\home\falconpulsar
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

# Honour the sentinel.
$sentinel = Join-Path $env:TEMP 'falconpulsar-distro.txt'
if (Test-Path $sentinel) {
    $Distro = (Get-Content $sentinel -Raw).Trim()
}

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
    if ($Interactive) {
        # Keep the console window open so the user can read the output.
        # cmd.exe /k holds the window after wsl.exe exits.
        $sc.TargetPath = "$env:WINDIR\System32\cmd.exe"
        $sc.Arguments  = "/k `"wsl.exe -d $Distro -u falconpulsar -- bash -ilc `"$BashCommand`"`""
    } else {
        $sc.TargetPath = "$env:WINDIR\System32\wsl.exe"
        $sc.Arguments = "-d $Distro -u falconpulsar -- bash -ilc `"$BashCommand`""
    }
    $sc.Description  = $Name
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

New-WslShortcut -Name 'Start FalconPulsar'   -BashCommand 'cd ~ && docker compose up -d'   -Interactive
New-WslShortcut -Name 'Stop FalconPulsar'    -BashCommand 'cd ~ && docker compose down'    -Interactive
New-WslShortcut -Name 'Restart FalconPulsar' -BashCommand 'cd ~ && docker compose restart' -Interactive
New-WslShortcut -Name 'Show Status'          -BashCommand 'cd ~ && docker compose ps'      -Interactive
New-WslShortcut -Name 'Tail Logs'            -BashCommand 'cd ~ && docker compose logs -f' -Interactive

# Open the falconpulsar user's home folder in Explorer via the wsl.localhost
# UNC path. Note that this requires WSL2 + Win11 (or Win10 build 21354+).
$linkPath = Join-Path $groupDir 'Open Stack Folder.lnk'
$sc = $shell.CreateShortcut($linkPath)
$sc.TargetPath   = 'explorer.exe'
$sc.Arguments    = "\\wsl.localhost\$Distro\home\falconpulsar"
$sc.Description  = 'Open the FalconPulsar stack folder in Windows Explorer'
$sc.Save()
Write-Info 'Created shortcut: Open Stack Folder'

Write-Output "[ok] Start Menu shortcuts created in $groupDir"
exit 0
