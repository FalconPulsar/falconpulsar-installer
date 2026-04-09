; =============================================================================
; FalconPulsar — Windows Installer (Inno Setup 6)
; =============================================================================
;
; This .iss script is compiled into FalconPulsar-Setup-vX.Y.Z.exe by either
; Inno Setup 6 on a Windows machine or by the build-windows GitHub Actions
; workflow. The compiled .exe is what users download from GitHub Releases.
;
; What the installer does (in order):
;
;   1. Pre-flight: Windows version, edition, x64, virtualization enabled
;   2. Custom welcome page
;   3. Custom admin-credentials page (username + password, double-entry)
;   4. Standard install location page (defaults to %PROGRAMFILES%\FalconPulsar)
;   5. Copies the bash installer + shared libs into the install dir
;   6. Runs the staged PowerShell helpers (00 → 50)
;        - check Windows prerequisites
;        - enable WSL2 if not present (may require reboot)
;        - install / detect Ubuntu 24.04 distro
;        - configure systemd in the distro
;        - run the bundled bash installer inside WSL
;        - register Start Menu shortcuts
;   7. Finish page with the URL to the local Web UI
;
; The installer is idempotent: re-running it after a Windows reboot picks up
; where it left off because every helper checks state before acting.
;
; Code signing is deferred for v0.1 — first launch will trigger a SmartScreen
; warning. Documented in windows/README-windows-build.md.
; =============================================================================

#define MyAppName        "FalconPulsar"
#define MyAppVersion     "0.1.0"
#define MyAppPublisher   "FalconPulsar Contributors"
#define MyAppURL         "https://github.com/FalconPulsar/falconpulsar-installer"
#define MyAppExeName     "FalconPulsar-Setup.exe"
#define WslDistroName    "Ubuntu-24.04"

[Setup]
AppId={{8E0B7C2F-3F4D-4B9E-9C6A-1D5F8A2B9C71}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; x64 only for Phase 2 — ARM64 Windows is Phase 3
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; WSL2 enable + Windows feature install requires admin
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=

OutputDir=.\Output
OutputBaseFilename=FalconPulsar-Setup-{#MyAppVersion}
; SetupIconFile is omitted for v0.1 — Inno Setup uses its default. A real
; icon will land before v1.0.
WizardStyle=modern
WizardSizePercent=120
Compression=lzma2/max
SolidCompression=yes
LicenseFile=assets\license.rtf

; The installer is unsigned for v0.1 — see README-windows-build.md.
; To sign, populate these:
; SignTool=signtool sign /fd sha256 /tr http://timestamp.digicert.com $f

; Minimum supported OS: Windows 10 22H2 (build 19045) — REQUIREMENTS.md
MinVersion=10.0.19045

UninstallDisplayName={#MyAppName} {#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; ── Bash installer + shared libs ────────────────────────────────────────────
; The whole linux/ and shared/ trees are copied verbatim into the install
; dir. The bootstrap PowerShell helper translates these paths into WSL
; mount paths (/mnt/c/...) when invoking bash inside the distro.
Source: "..\linux\install.sh";                              DestDir: "{app}\linux";          Flags: ignoreversion
Source: "..\linux\uninstall.sh";                            DestDir: "{app}\linux";          Flags: ignoreversion
Source: "..\linux\systemd\falconpulsar.service.template";   DestDir: "{app}\linux\systemd";  Flags: ignoreversion
Source: "..\shared\compose.yml";                            DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\init.example.json";                      DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\lib\common.sh";                          DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\checks.sh";                          DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\prompts.sh";                         DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\bootstrap.sh";                       DestDir: "{app}\shared\lib";     Flags: ignoreversion

; ── PowerShell helpers ──────────────────────────────────────────────────────
Source: "helpers\lib.ps1";                                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\00-check-prereqs.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\10-enable-wsl.ps1";                        DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\20-install-distro.ps1";                    DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\30-configure-distro.ps1";                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\40-run-fp-installer.ps1";                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\50-register-shortcuts.ps1";                DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\uninstall.ps1";                            DestDir: "{app}\helpers";        Flags: ignoreversion

; ── Assets + reference files ────────────────────────────────────────────────
Source: "assets\license.rtf";                               DestDir: "{app}\assets";         Flags: ignoreversion
Source: "..\REQUIREMENTS.md";                               DestDir: "{app}";                Flags: ignoreversion
Source: "..\README.md";                                     DestDir: "{app}";                Flags: ignoreversion

[Run]
; Open the Web UI in the default browser at the end (postinstall checkbox).
; The actual install steps are run from the [Code] section below in
; CurStepChanged(ssInstall) so that we can:
;   - capture each step's output to a single log file
;   - show a clear error dialog (with the last 2000 chars of the log) on
;     any failure, instead of Inno Setup's generic "command failed" dialog
;   - check Docker Desktop / WSL Integration state up front
Filename: "http://localhost:8080"; \
    Description: "Open the FalconPulsar Web UI"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\helpers\uninstall.ps1"" -Distro {#WslDistroName}"; \
    Flags: runhidden waituntilterminated

[Code]
// =============================================================================
// Pascal Script — custom pages, prereq checks, install orchestrator
// =============================================================================

var
  CredentialsPage: TInputQueryWizardPage;
  FpLogFile: String;

// ── Helper: locate the install log file ────────────────────────────────────
// Both the Pascal Script orchestrator AND lib.ps1 derive this exact path
// from %TEMP%, so they both write to the same file.
function GetInstallLogPath(): String;
begin
  Result := AddBackslash(GetEnv('TEMP')) + 'falconpulsar-install.log';
end;

// ── Helper: read the tail of the log file for the error dialog ─────────────
function ReadLogTail(): String;
var
  LogText: AnsiString;
begin
  if not LoadStringFromFile(FpLogFile, LogText) then
  begin
    Result := '(install log file not found at ' + FpLogFile + ')';
    Exit;
  end;
  // Cap the dialog content at ~2000 chars so it fits on screen.
  if Length(LogText) > 2000 then
    Result := '...(truncated — see full log)' + #13#10 +
              Copy(LogText, Length(LogText) - 1900, 2000)
  else
    Result := LogText;
end;

// ── Helper: show an error dialog with log tail and abort ───────────────────
procedure ShowStepError(StepName: String; ExitCode: Integer);
begin
  MsgBox(
    'FalconPulsar install failed at: ' + StepName + #13#10 +
    'Exit code: ' + IntToStr(ExitCode) + #13#10 + #13#10 +
    'Last lines from the install log:' + #13#10 +
    '----------------------------------------' + #13#10 +
    ReadLogTail() + #13#10 +
    '----------------------------------------' + #13#10 + #13#10 +
    'Full log file: ' + FpLogFile + #13#10 +
    'Please attach this file to any bug report.',
    mbError,
    MB_OK
  );
end;

// ── Helper: run one PowerShell helper, return True on success ──────────────
function RunHelper(ScriptName: String; ExtraArgs: String; StatusMsg: String): Boolean;
var
  ResultCode: Integer;
  HelperPath: String;
  FullArgs: String;
begin
  // Update the wizard status label so the user sees what's happening
  WizardForm.StatusLabel.Caption := StatusMsg;
  WizardForm.Refresh();

  HelperPath := ExpandConstant('{app}\helpers\') + ScriptName;
  FullArgs := '-NoProfile -ExecutionPolicy Bypass -File "' + HelperPath + '"';
  if Length(ExtraArgs) > 0 then
    FullArgs := FullArgs + ' ' + ExtraArgs;

  // Append a marker line to the log so the user can see step boundaries
  SaveStringToFile(FpLogFile, #13#10 + '################ ' + ScriptName + ' ################' + #13#10, True);

  if not Exec('powershell.exe', FullArgs, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    ShowStepError(StatusMsg, -1);
    Result := False;
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    ShowStepError(StatusMsg, ResultCode);
    Result := False;
    Exit;
  end;

  Result := True;
end;

// ── Install orchestrator ───────────────────────────────────────────────────
// Called by Inno Setup at each install step transition. We hook ssInstall
// (right after files are copied, before any [Run] entries) and run the six
// PowerShell helpers in order. If any helper fails, ShowStepError pops up a
// dialog with the log tail and we Abort, which cleanly stops the install
// at the current page so the user can click Cancel.
procedure CurStepChanged(CurStep: TSetupStep);
var
  AdminUserArg: String;
  AdminPassArg: String;
  AppDirArg: String;
begin
  if CurStep = ssInstall then
  begin
    FpLogFile := GetInstallLogPath();

    // Truncate the log at the start of the install run. lib.ps1 always
    // appends — never overwrites — so this is the single point of init.
    SaveStringToFile(FpLogFile,
      '=== FalconPulsar Windows installer log — ' +
      GetDateTimeString('yyyy/mm/dd hh:nn:ss', '-', ':') + ' ===' + #13#10,
      False);

    AdminUserArg := '-AdminUser "' + CredentialsPage.Values[0] + '"';
    AdminPassArg := '-AdminPass "' + CredentialsPage.Values[1] + '"';
    AppDirArg    := '-InstallDir "' + ExpandConstant('{app}') + '"';

    if not RunHelper('00-check-prereqs.ps1', '',
        'Checking system prerequisites...') then Abort;

    if not RunHelper('10-enable-wsl.ps1', '',
        'Enabling WSL2 (this may take several minutes on first run)...') then Abort;

    if not RunHelper('20-install-distro.ps1', '-Distro {#WslDistroName}',
        'Installing Ubuntu 24.04 inside WSL (downloading ~500 MB)...') then Abort;

    if not RunHelper('30-configure-distro.ps1', '-Distro {#WslDistroName}',
        'Configuring systemd inside WSL...') then Abort;

    if not RunHelper('40-run-fp-installer.ps1',
        '-Distro {#WslDistroName} ' + AppDirArg + ' ' + AdminUserArg + ' ' + AdminPassArg,
        'Installing FalconPulsar inside WSL (this may take 5-10 minutes)...') then Abort;

    if not RunHelper('50-register-shortcuts.ps1',
        '-Distro {#WslDistroName} ' + AppDirArg,
        'Registering Start Menu shortcuts...') then Abort;
  end;
end;

// Custom page: admin username + password (double-entry).
procedure InitializeWizard;
begin
  CredentialsPage := CreateInputQueryPage(
    wpWelcome,
    'FalconPulsar Admin Credentials',
    'Set the administrator account for the FalconPulsar database',
    'These credentials will be used to log in to the FalconPulsar Web UI ' +
    'at http://localhost:8080. The password is NOT stored on disk anywhere ' +
    'after the install — the installer uses it once to bootstrap the admin ' +
    'user and then exchanges it for a service token. Save it now.');

  CredentialsPage.Add('Admin username:', False);
  CredentialsPage.Add('Admin password:', True);
  CredentialsPage.Add('Confirm password:', True);

  CredentialsPage.Values[0] := 'admin';

  // Bring the wizard to the foreground after UAC elevation. Windows
  // suppresses focus theft from new processes by default, so the elevated
  // setup.exe lands in the taskbar instead of on top of the user's desktop.
  // Calling BringToFront() from InitializeWizard runs after the form is
  // realized and shoves it back to the foreground.
  WizardForm.BringToFront();
end;

// Validate the credentials page when the user clicks Next.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = CredentialsPage.ID then
  begin
    if Length(CredentialsPage.Values[0]) < 1 then
    begin
      MsgBox('Admin username cannot be empty.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if Length(CredentialsPage.Values[1]) < 10 then
    begin
      MsgBox('Admin password must be at least 10 characters.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if CredentialsPage.Values[1] <> CredentialsPage.Values[2] then
    begin
      MsgBox('The two passwords do not match.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

// Forward the credentials to the [Run] section via {code:GetAdminUser} /
// {code:GetAdminPass} parameter substitution.
function GetAdminUser(Param: String): String;
begin
  Result := CredentialsPage.Values[0];
end;

function GetAdminPass(Param: String): String;
begin
  Result := CredentialsPage.Values[1];
end;

// Top-level prereq check before any page is shown. Anything that's a
// hard-no goes here so the user gets a clear error before they even see
// the welcome screen.
function InitializeSetup(): Boolean;
var
  WinVer: TWindowsVersion;
begin
  Result := True;

  GetWindowsVersionEx(WinVer);

  // Refuse Windows older than 10.0.19045 (Windows 10 22H2).
  if (WinVer.Major < 10) or
     ((WinVer.Major = 10) and (WinVer.Build < 19045)) then
  begin
    MsgBox('FalconPulsar requires Windows 10 22H2 (build 19045) or newer.' + #13#10 +
           'See REQUIREMENTS.md for the full list of supported versions.',
           mbError, MB_OK);
    Result := False;
    Exit;
  end;

  // Refuse 32-bit installs (we declare x64compatible above, but belt-and-braces).
  if not IsX64Compatible() then
  begin
    MsgBox('FalconPulsar requires a 64-bit (x64) Windows installation.',
           mbError, MB_OK);
    Result := False;
    Exit;
  end;
end;
