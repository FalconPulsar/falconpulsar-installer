# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# lib.ps1 -- shared helpers for the FalconPulsar Windows installer scripts.
#
# Dot-sourced by every helper. Provides:
#
#   Write-Step      coloured section banner
#   Write-Info      info-level log line
#   Write-Warn      warning-level log line
#   Write-Err       error-level log line
#   Stop-WithError  print error + exit 1
#   Test-Wsl2Enabled            does the Windows host have WSL2?
#   Test-WslDistroPresent       is a given WSL distro registered?
#   Get-WslDistroVersion        WSL version (1 or 2) of a registered distro
#   Invoke-WslBash              run a bash command inside a distro safely
#   ConvertTo-WslPath           translate C:\foo\bar to /mnt/c/foo/bar
#
# All output goes to stdout/stderr -- Inno Setup captures it into the install
# log file at %TEMP%\Setup Log YYYY-MM-DD #NNN.txt which the user can attach
# to a bug report. We deliberately do NOT use Write-Host with -ForegroundColor
# because Inno Setup runs PowerShell hidden and the colour escapes end up
# polluting the log.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Log file -----------------------------------------------------------------
# Every helper appends to a single log file at %TEMP%\falconpulsar-install.log.
# The Inno Setup orchestrator reads this file when a helper fails so the user
# sees what went wrong instead of a silent abort. The path is hard-coded so
# the orchestrator and the helpers agree without having to pass it as a
# parameter to every script.

$Script:FpLogPath = Join-Path $env:TEMP 'falconpulsar-install.log'

function Write-FpLogLine {
    param([AllowEmptyString()] [string] $Line = '')
    try {
        Add-Content -Path $Script:FpLogPath -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # ignore
    }
}

function Write-Step {
    param([AllowEmptyString()] [string] $Message = '')
    Write-Output ''
    Write-Output "==> $Message"
    Write-FpLogLine ''
    Write-FpLogLine "==> $Message"
}

function Write-Info {
    param([Parameter(Mandatory)] [string] $Message)
    $line = "[info] $Message"
    Write-Output $line
    Write-FpLogLine $line
}

function Write-Warn {
    param([Parameter(Mandatory)] [string] $Message)
    $line = "[warn] $Message"
    Write-Output $line
    Write-FpLogLine $line
}

function Write-Err {
    param([Parameter(Mandatory)] [string] $Message)
    $line = "[error] $Message"
    [Console]::Error.WriteLine($line)
    Write-FpLogLine $line
}

function Stop-WithError {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Err $Message
    exit 1
}

# Note: the log file is truncated by the Inno Setup orchestrator at the
# start of each install run (in CurStepChanged(ssInstall)). Each helper
# always appends -- never overwrites.

# -- Windows feature / WSL probes --------------------------------------------

# Returns $true if both required Windows features are enabled. We check
# Microsoft-Windows-Subsystem-Linux (the WSL feature itself) and
# VirtualMachinePlatform (required for WSL2).
function Test-Wsl2Enabled {
    try {
        $wsl  = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction Stop
        $vmp  = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -ErrorAction Stop
        return ($wsl.State -eq 'Enabled') -and ($vmp.State -eq 'Enabled')
    } catch {
        return $false
    }
}

# Returns $true if `wsl --status` reports a working installation.
function Test-WslWorking {
    try {
        $null = & wsl.exe --status 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# -- Distro helpers ----------------------------------------------------------

# `wsl --list --quiet` outputs UTF-16 by default. Decode + trim each line.
function Get-WslDistros {
    if (-not (Test-WslWorking)) { return @() }

    # Force unicode output to avoid the UTF-16 BOM mess.
    $output = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    $result = $output | ForEach-Object {
        # Strip null bytes that the UTF-16 -> ASCII reinterpretation can leave.
        ($_ -replace "`0", '').Trim()
    } | Where-Object { $_ -ne '' }
    # ALWAYS return a real array. With zero distros the pipeline emits
    # nothing, so a bare `return $result` hands back AutomationNull — and
    # under `Set-StrictMode -Version Latest` a caller doing `.Count` on that
    # throws PropertyNotFoundStrict (this broke clean-server installs). The
    # leading comma prevents PowerShell from unrolling the empty array back
    # to null at the call site (a plain `@($result)` return would).
    return ,@($result)
}

function Test-WslDistroPresent {
    param([Parameter(Mandatory)] [string] $Name)
    return (Get-WslDistros) -contains $Name
}

# Returns 1 or 2 (WSL version), or $null if the distro isn't installed.
function Get-WslDistroVersion {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Test-WslDistroPresent -Name $Name)) { return $null }

    $output = & wsl.exe --list --verbose 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    foreach ($line in $output) {
        $clean = ($line -replace "`0", '').Trim()
        if ($clean -match "^\*?\s*$([regex]::Escape($Name))\s+\S+\s+(\d+)") {
            return [int] $matches[1]
        }
    }
    return $null
}

# -- Bash invocation ---------------------------------------------------------

# Invoke-WslBash <distro> <bash-script-string>
#
# Runs a bash command inside the given distro as the root user (because
# WSL --user defaults to whatever user is set in /etc/wsl.conf, which is
# unreliable on first install). Captures stdout + stderr into the install
# log and propagates the exit code.
function Invoke-WslBash {
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [Parameter(Mandatory)] [string] $Script,
        [string] $User = 'root'
    )

    # Strip Windows CRLF line endings -- PowerShell heredocs use \r\n but
    # bash inside WSL treats \r as a literal character, corrupting paths
    # and commands (e.g. '/opt/dir'$'\r' instead of '/opt/dir').
    $Script = $Script -replace "`r", ''

    # Write the script to a temp file and run `bash /path/to/file.sh`
    # instead of `bash -c "..."`. This avoids ALL quoting, argument
    # splitting, and pipeline issues that plague the bash -c approach
    # when multi-line scripts pass through PowerShell -> wsl.exe.
    $scriptFile = Join-Path $env:TEMP 'fp-wsl-run.sh'
    [System.IO.File]::WriteAllText($scriptFile, $Script, (New-Object System.Text.UTF8Encoding $false))
    $wslPath = ConvertTo-WslPath $scriptFile

    # Start-Process -Wait -PassThru gives us:
    #   - clean exit code via $proc.ExitCode (no pipeline pollution)
    #   - output goes to the log file (via lib.ps1 Write-Info in callers)
    # -RedirectStandardOutput captures stdout so we can log it.
    $outFile = Join-Path $env:TEMP 'fp-wsl-stdout.txt'
    $errFile = Join-Path $env:TEMP 'fp-wsl-stderr.txt'
    $proc = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList "-d $Distro -u $User -- bash `"$wslPath`"" `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile

    # Display captured output. Use Write-Host (not Write-Info) to avoid
    # polluting the PowerShell pipeline -- Write-Info calls Write-Output
    # which would make $rc = Invoke-WslBash(...) capture the text as
    # part of the return value. Write-FpLogLine logs to the file.
    if (Test-Path $outFile) {
        Get-Content $outFile | ForEach-Object {
            Write-Host $_
            Write-FpLogLine $_
        }
        Remove-Item $outFile -ErrorAction SilentlyContinue
    }
    if (Test-Path $errFile) {
        $errContent = Get-Content $errFile -Raw
        if ($errContent -and $errContent.Trim().Length -gt 0) {
            $errContent.Trim().Split("`n") | ForEach-Object {
                Write-Host $_
                Write-FpLogLine $_
            }
        }
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }

    $ec = $proc.ExitCode
    Remove-Item $scriptFile -ErrorAction SilentlyContinue
    return $ec
}

# Admin authentication against the FalconPulsar Core REST API. Used by the
# uninstaller to require the admin password before destructive actions.
# Shows a modal WinForms dialog (title, message, red inline error), retries up
# to maxAttempts, verifies role=admin via /auth/me. Returns $true on success.
function Assert-AdminAuth {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message,
        [int] $MaxAttempts = 3,
        [string] $BaseUrl = 'http://localhost:7433',
        [switch] $AllowBypassIfCoreDown
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Probe Core first. If it's down AND the caller accepts a bypass, fall
    # back to an explicit YES confirmation (matches the bash uninstaller's
    # code-2 behaviour on macOS/Linux).
    $coreReachable = $true
    try {
        $null = Invoke-WebRequest -Uri "$BaseUrl/api/v1/auth/login" `
            -Method Options -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
    } catch [System.Net.WebException] {
        $status = $_.Exception.Status
        if ($status -eq [System.Net.WebExceptionStatus]::ConnectFailure -or
            $status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure -or
            $status -eq [System.Net.WebExceptionStatus]::Timeout) {
            $coreReachable = $false
        }
    } catch {
        # Non-WebException -- unknown, treat as reachable; the login POST below
        # will fail fast if it truly isn't.
    }

    if (-not $coreReachable) {
        if ($AllowBypassIfCoreDown) {
            # Ask the user to explicitly authorise by typing YES. This is the
            # equivalent of the bash YES-fallback when Core can't verify the
            # password.
            $bypassForm = New-Object System.Windows.Forms.Form
            $bypassForm.Text = $Title
            $bypassForm.Width = 430; $bypassForm.Height = 210
            $bypassForm.FormBorderStyle = 'FixedDialog'
            $bypassForm.StartPosition = 'CenterScreen'
            $bypassForm.MinimizeBox = $false; $bypassForm.MaximizeBox = $false
            $bypassForm.TopMost = $true

            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = "FalconPulsar Core is not running, so the admin password cannot be verified.`r`n`r`nTo authorize anyway, type YES (uppercase):"
            $lbl.AutoSize = $false; $lbl.Width = 390; $lbl.Height = 70
            $lbl.Top = 15; $lbl.Left = 15
            $bypassForm.Controls.Add($lbl)

            $box = New-Object System.Windows.Forms.TextBox
            $box.Width = 120; $box.Top = 95; $box.Left = 15
            $bypassForm.Controls.Add($box)

            $ok = New-Object System.Windows.Forms.Button
            $ok.Text = 'Continue'; $ok.DialogResult = 'OK'
            $ok.Width = 90; $ok.Top = 135; $ok.Left = 215
            $bypassForm.Controls.Add($ok); $bypassForm.AcceptButton = $ok

            $cancel = New-Object System.Windows.Forms.Button
            $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
            $cancel.Width = 90; $cancel.Top = 135; $cancel.Left = 310
            $bypassForm.Controls.Add($cancel); $bypassForm.CancelButton = $cancel

            $result = $bypassForm.ShowDialog()
            $typed = $box.Text
            $bypassForm.Dispose()

            if ($result -ne [System.Windows.Forms.DialogResult]::OK -or $typed -ne 'YES') {
                return $false
            }
            return $true
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Cannot reach FalconPulsar Core at $BaseUrl.`nStart the stack first and try again.",
                'Core not reachable',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return $false
        }
    }

    $attempt = 0
    $lastUser = 'admin'
    $errorText = $null
    while ($attempt -lt $MaxAttempts) {
        $hasError = -not [string]::IsNullOrEmpty($errorText)
        $errorOffset = if ($hasError) { 28 } else { 0 }
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.Width = 380
        $form.Height = 220 + $errorOffset
        $form.FormBorderStyle = 'FixedDialog'
        $form.StartPosition = 'CenterScreen'
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.TopMost = $true

        $msg = New-Object System.Windows.Forms.Label
        $msg.Text = $Message; $msg.AutoSize = $false
        $msg.Width = 340; $msg.Height = 40; $msg.Top = 10; $msg.Left = 15
        $form.Controls.Add($msg)

        if ($hasError) {
            $err = New-Object System.Windows.Forms.Label
            $err.Text = $errorText; $err.AutoSize = $false
            $err.Width = 340; $err.Height = 22; $err.Top = 52; $err.Left = 15
            $err.ForeColor = [System.Drawing.Color]::Firebrick
            $err.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
            $form.Controls.Add($err)
        }

        $userLabel = New-Object System.Windows.Forms.Label
        $userLabel.Text = 'Admin username:'; $userLabel.Width = 120
        $userLabel.Top = 60 + $errorOffset; $userLabel.Left = 15
        $form.Controls.Add($userLabel)

        $userBox = New-Object System.Windows.Forms.TextBox
        $userBox.Width = 220; $userBox.Top = 58 + $errorOffset; $userBox.Left = 140
        $userBox.Text = $lastUser
        $form.Controls.Add($userBox)

        $passLabel = New-Object System.Windows.Forms.Label
        $passLabel.Text = 'Admin password:'; $passLabel.Width = 120
        $passLabel.Top = 92 + $errorOffset; $passLabel.Left = 15
        $form.Controls.Add($passLabel)

        $passBox = New-Object System.Windows.Forms.TextBox
        $passBox.Width = 220; $passBox.Top = 90 + $errorOffset; $passBox.Left = 140
        $passBox.UseSystemPasswordChar = $true
        $form.Controls.Add($passBox)

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = 'Continue'; $okBtn.DialogResult = 'OK'
        $okBtn.Width = 90; $okBtn.Top = 135 + $errorOffset; $okBtn.Left = 175
        $form.Controls.Add($okBtn); $form.AcceptButton = $okBtn

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = 'Cancel'; $cancelBtn.DialogResult = 'Cancel'
        $cancelBtn.Width = 90; $cancelBtn.Top = 135 + $errorOffset; $cancelBtn.Left = 270
        $form.Controls.Add($cancelBtn); $form.CancelButton = $cancelBtn

        $dr = $form.ShowDialog()
        $user = $userBox.Text; $pass = $passBox.Text
        $form.Dispose()

        if ($dr -ne [System.Windows.Forms.DialogResult]::OK) {
            return $false   # user cancelled
        }
        $lastUser = $user

        try {
            $body = @{ username = $user; password = $pass } | ConvertTo-Json -Compress
            $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method Post `
                -ContentType 'application/json' -Body $body -TimeoutSec 10
            $jwt = $resp.token
            if ([string]::IsNullOrEmpty($jwt)) { throw "No token returned by server." }

            $me = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/me" -Method Get `
                -Headers @{ Authorization = "Bearer $jwt" } -TimeoutSec 10
            $role = if ($me.role) { $me.role } elseif ($me.roles) { $me.roles[0] } else { '' }
            if ($role -ne 'admin') {
                throw "This account is not an administrator."
            }
            return $true
        } catch {
            $msg = $_.Exception.Message
            # Translate common network errors to actionable text.
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
                $msg = 'Incorrect username or password.'
            } elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 403) {
                $msg = 'Access denied.'
            }
            $attempt++
            $errorText = $msg
            if ($attempt -ge $MaxAttempts) { break }
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        'Please verify your admin credentials and try again later.',
        'Too many failed attempts',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return $false
}

# Translate a Windows path to its WSL mount path.
# C:\Program Files\FalconPulsar  ->  /mnt/c/Program Files/FalconPulsar
function ConvertTo-WslPath {
    param([Parameter(Mandatory)] [string] $WindowsPath)

    $abs = (Resolve-Path -LiteralPath $WindowsPath -ErrorAction SilentlyContinue)
    if ($null -eq $abs) {
        # Path may not exist yet -- best-effort literal conversion.
        $abs = $WindowsPath
    } else {
        $abs = $abs.Path
    }

    if ($abs -notmatch '^[A-Za-z]:[\\/]') {
        throw "Cannot convert non-absolute Windows path: $WindowsPath"
    }

    $drive = $abs.Substring(0, 1).ToLower()
    $rest  = $abs.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}
