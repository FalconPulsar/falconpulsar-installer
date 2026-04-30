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
#define MyAppVersion     "0.1.3"
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
SetupIconFile=assets\falcon.ico
WizardStyle=modern
DisableWelcomePage=no
WizardSizePercent=120
WizardImageFile=assets\welcome.bmp
WizardSmallImageFile=assets\header.bmp
WizardImageStretch=no
UninstallDisplayIcon={app}\assets\falcon.ico
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

[Messages]
; Custom welcome page text. WelcomeLabel1 is the bold heading; WelcomeLabel2
; is the body paragraph beneath it. Inno Setup wraps the body to the panel
; width automatically — keep paragraphs short.
WelcomeLabel1=FalconPulsar
WelcomeLabel2=Version {#MyAppVersion}%n%nDetecting your environment...

; Finish page — point the user at the Web UI
FinishedLabel=FalconPulsar is now installed and running on your computer.%n%nOpen %1 in any web browser to log in to the Web UI with the admin credentials you set during this install. The admin password is NOT stored on disk anywhere — make sure you saved it.%n%nConsole tool:%n   %localappdata%\falconpulsar\bin\fp.exe%nRun it for the interactive console, or with subcommands for scripts: status · start · stop · logs · config export · config import.%n%nClick Finish to exit Setup.

[Files]
; ── Bash installer + shared libs ────────────────────────────────────────────
; The whole linux/ and shared/ trees are copied verbatim into the install
; dir. The bootstrap PowerShell helper translates these paths into WSL
; mount paths (/mnt/c/...) when invoking bash inside the distro.
Source: "..\linux\install.sh";                              DestDir: "{app}\linux";          Flags: ignoreversion
Source: "..\linux\uninstall.sh";                            DestDir: "{app}\linux";          Flags: ignoreversion
Source: "..\linux\systemd\falconpulsar.service.template";   DestDir: "{app}\linux\systemd";  Flags: ignoreversion
Source: "..\shared\compose.yml";                            DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\gateway.yaml";                           DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\nginx.conf";                             DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\init.example.json";                      DestDir: "{app}\shared";         Flags: ignoreversion
Source: "..\shared\lib\common.sh";                          DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\checks.sh";                          DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\prompts.sh";                         DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\bootstrap.sh";                       DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\registry_auth.sh";                   DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\fpcli.sh";                           DestDir: "{app}\shared\lib";     Flags: ignoreversion
Source: "..\shared\lib\existing.sh";                        DestDir: "{app}\shared\lib";     Flags: ignoreversion

; ── PowerShell helpers ──────────────────────────────────────────────────────
Source: "helpers\lib.ps1";                                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\05-detect-environment.ps1";                 DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\06-detect-existing-install.ps1";            DestDir: "{app}\helpers";        Flags: ignoreversion
; Also include detection files for temp extraction (ExtractTemporaryFile)
; so they can run before {app} is initialized. dontcopy = only extracted
; on demand via Pascal Script, not during normal [Files] processing.
Source: "helpers\05-detect-environment.ps1";                                                     Flags: dontcopy
Source: "helpers\06-detect-existing-install.ps1";                                                Flags: dontcopy
Source: "helpers\lib.ps1";                                                                       Flags: dontcopy
Source: "helpers\00-check-prereqs.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\10-enable-wsl.ps1";                        DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\20-install-distro.ps1";                    DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\25-test-registry.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\30-configure-distro.ps1";                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\40-run-fp-installer.ps1";                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\45-verify-health.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\50-register-shortcuts.ps1";                DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\uninstall.ps1";                            DestDir: "{app}\helpers";        Flags: ignoreversion

; ── Tray app ──────────────────────────────────────────────────────────────
Source: "tray-app\publish\FalconPulsarTray.exe";            DestDir: "{app}";                Flags: ignoreversion

; ── fp console CLI ────────────────────────────────────────────────────────
; Cross-compiled by CI from console/ via `GOOS=windows GOARCH=amd64`.
; Drops fp.exe (the WSL-forwarding wrapper) into %LOCALAPPDATA%\falconpulsar\bin\
; so everything stays under the stack's own folder (user-level install, no
; admin needed). The real Linux `fp` binary is bundled alongside and staged
; into /home/falconpulsar/bin/fp by 40-run-fp-installer.ps1 during install.
Source: "..\console\dist\fp-windows-amd64.exe"; \
    DestDir: "{localappdata}\falconpulsar\bin"; \
    DestName: "fp.exe"; \
    Flags: ignoreversion
; Drop a second copy into %LOCALAPPDATA%\Microsoft\WindowsApps\ so `fp` is on
; PATH without depending on the [Tasks] checkbox or a shell restart.
; Windows puts that folder on every user's PATH at login (Win10 1709+), and
; PATH is scanned per-lookup -- so even shells opened BEFORE install pick up
; fp.exe immediately. Inno Setup auto-removes this on uninstall (default
; behavior for [Files] entries).
Source: "..\console\dist\fp-windows-amd64.exe"; \
    DestDir: "{localappdata}\Microsoft\WindowsApps"; \
    DestName: "fp.exe"; \
    Flags: ignoreversion
Source: "..\console\dist\fp-linux-amd64"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

; ── Assets + reference files ────────────────────────────────────────────────
Source: "assets\license.rtf";                               DestDir: "{app}\assets";         Flags: ignoreversion
Source: "assets\falcon.ico";                                DestDir: "{app}\assets";         Flags: ignoreversion
Source: "..\REQUIREMENTS.md";                               DestDir: "{app}";                Flags: ignoreversion
Source: "..\README.md";                                     DestDir: "{app}";                Flags: ignoreversion

[Tasks]
Name: "aigateway"; \
    Description: "Install AI Capabilities (requires an LLM API key or local Ollama — can be enabled later with fp ai enable)"; \
    GroupDescription: "AI Capabilities:"; \
    Flags: unchecked

; Front-door HTTPS declaration. Drives the Secure flag and __Host- prefix
; on session cookies. Checked by default (recommended for any deployment
; reachable via HTTPS, including localhost on a TLS-fronted setup).
; Uncheck ONLY for HTTP-only deployments on trusted LANs accessed by IP —
; without Secure cookies, sessions are vulnerable to LAN sniffing.
Name: "cookiesecure"; \
    Description: "Use HTTPS at the front door (recommended). Uncheck only for HTTP-only LAN deployments — without HTTPS, session cookies are vulnerable to network sniffing."; \
    GroupDescription: "Security:"

[Run]
; Open the Web UI in the default browser at the end (postinstall checkbox).
; The actual install steps are run from the [Code] section below in
; CurStepChanged(ssInstall) so that we can:
;   - capture each step's output to a single log file
;   - show a clear error dialog (with the last 2000 chars of the log) on
;     any failure, instead of Inno Setup's generic "command failed" dialog
;   - check Docker Desktop / WSL Integration state up front
Filename: "{app}\FalconPulsarTray.exe"; \
    Description: "Launch FalconPulsar Tray Manager"; Flags: postinstall nowait skipifsilent
Filename: "http://localhost:8080"; \
    Description: "Open the FalconPulsar Web UI"; Flags: postinstall shellexec skipifsilent nowait unchecked
Filename: "notepad.exe"; Parameters: "{code:GetLogPath}"; \
    Description: "View install log"; Flags: postinstall shellexec skipifsilent nowait unchecked

[Registry]
; Auto-start the tray app on Windows login
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; \
    ValueName: "FalconPulsar"; ValueType: string; \
    ValueData: """{app}\FalconPulsarTray.exe"""; Flags: uninsdeletevalue

; fp.exe is installed to %LOCALAPPDATA%\Microsoft\WindowsApps\ in the [Files]
; section above, which is already on every Windows user's PATH (Win10 1709+,
; set there by Windows itself). No HKCU\Environment\Path writes needed -- the
; previous design that appended here caused 26-copy PATH bloat because Inno
; Setup has no auto-remove for appended registry entries.

[UninstallDelete]
Type: filesandordirs; Name: "{commonprograms}\FalconPulsar"

[UninstallRun]
; Uninstall is now handled by CurUninstallStepChanged in [Code]
; which shows options to the user before calling uninstall.ps1.

[Code]
// =============================================================================
// Pascal Script -- custom pages, prereq checks, install orchestrator
//
// Wizard flow:
//   Welcome -> Legal -> Distro Selection (if multiple) -> Registry
//   -> Credentials -> Directory -> Install -> Finish
//
// Environment detection runs at InitializeSetup via 05-detect-environment.ps1
// which writes %TEMP%\falconpulsar-detect.txt. The results drive:
//   - whether the Distro Selection page is shown
//   - which distro name is passed to all helpers
//   - whether WSL/distro install steps are skipped
//   - which Docker engine the Test Connection button uses
// =============================================================================

const
  MAX_DISTROS = 20;
  STEP_COUNT = 7;

var
  StepLabels: array[0..6] of TNewStaticText;
  StepNames: array[0..6] of String;
  CredentialsPage: TWizardPage;
  CredUserEdit: TNewEdit;
  CredPassEdit: TNewEdit;
  CredConfirmEdit: TNewEdit;
  CredStrengthLabel: TNewStaticText;
  CredCharCountLabel: TNewStaticText;
  CredGeneratedLabel: TNewEdit;
  CredGeneratedCaption: TNewStaticText;
  CopyButton: TNewButton;
  LegalPage: TWizardPage;
  LegalCheckBox: TNewCheckBox;
  DistroPage: TWizardPage;
  DistroRadios: array[0..MAX_DISTROS] of TNewRadioButton;
  DistroLabels: array[0..MAX_DISTROS] of TNewStaticText;
  DistroNames: array[0..MAX_DISTROS] of String;
  DistroCompatible: array[0..MAX_DISTROS] of String;
  DistroHasDocker: array[0..MAX_DISTROS] of String;
  DistroCount: Integer;
  RegistryPage: TWizardPage;
  RegistryUrlEdit: TNewEdit;
  RegistryUserEdit: TNewEdit;
  RegistryPassEdit: TNewEdit;
  RegistrySkipCheck: TNewCheckBox;
  RegistryTestButton: TNewButton;
  RegistryStatusLabel: TNewStaticText;
  IsUpgrade: Boolean;
  InstallAction: String;   // 'upgrade' | 'reinstall' | 'fresh'
  FpLogFile: String;
  DetectedWslStatus: String;
  DetectedDockerDesktop: String;
  SelectedDistro: String;
  NeedWslInstall: Boolean;
  NeedDistroInstall: Boolean;
  DetectionDone: Boolean;

  // Existing-install detection (populated by 06-detect-existing-install.ps1
  // during InitializeWizard). Matches the fields in the macOS installer's
  // ExistingInstall struct so the UX is consistent across platforms.
  ExistingPage: TWizardPage;
  ExistingInventoryLabel: TNewStaticText;
  ExistingUpgradeRadio: TNewRadioButton;
  ExistingReinstallRadio: TNewRadioButton;
  ExistingFreshRadio: TNewRadioButton;
  ExistingFreshWarnLabel: TNewStaticText;
  ExistingFreshConfirmLabel: TNewStaticText;
  ExistingFreshConfirmEdit: TNewEdit;
  ExistingRemoveImagesCheck: TNewCheckBox;
  ExistingDetectionDone: Boolean;
  ExistingHasPrior: Boolean;
  ExistingHasData: Boolean;
  ExistingHasContainers: Boolean;
  ExistingHasImages: Boolean;
  ExistingInventoryText: String;

// Create the installation checklist on the Installing (progress) page.
// Called once at the start of the install phase.
procedure CreateChecklist();
var
  I, Y: Integer;
begin
  StepNames[0] := 'System prerequisites';
  StepNames[1] := 'Enable WSL2';
  StepNames[2] := 'Install Linux distro';
  StepNames[3] := 'Configure systemd';
  StepNames[4] := 'FalconPulsar installer';
  StepNames[5] := 'Verify installation';
  StepNames[6] := 'Start Menu shortcuts';

  // Hide the built-in progress bar and status label -- the checklist
  // provides better feedback.
  WizardForm.ProgressGauge.Visible := False;
  WizardForm.StatusLabel.Visible := False;

  Y := ScaleY(10);
  for I := 0 to STEP_COUNT - 1 do
  begin
    StepLabels[I] := TNewStaticText.Create(WizardForm);
    StepLabels[I].Parent := WizardForm.InnerPage;
    StepLabels[I].Left   := ScaleX(10);
    StepLabels[I].Top    := Y;
    StepLabels[I].Width  := WizardForm.InnerPage.Width - ScaleX(20);
    StepLabels[I].Caption := '[ ] ' + StepNames[I];
    StepLabels[I].Font.Size := 9;
    Y := Y + ScaleY(18);
  end;
end;

// Update a single step in the checklist.
//   status: 'current' | 'done' | 'fail' | 'skip'
procedure UpdateStep(Index: Integer; Status: String);
begin
  if (Index < 0) or (Index >= STEP_COUNT) then Exit;
  if StepLabels[Index] = nil then Exit;

  if Status = 'current' then
  begin
    StepLabels[Index].Caption := '[-] ' + StepNames[Index] + '...';
    StepLabels[Index].Font.Color := clBlue;
    StepLabels[Index].Font.Style := [fsBold];
  end
  else if Status = 'done' then
  begin
    StepLabels[Index].Caption := '[OK] ' + StepNames[Index];
    StepLabels[Index].Font.Color := clGreen;
    StepLabels[Index].Font.Style := [];
  end
  else if Status = 'fail' then
  begin
    StepLabels[Index].Caption := '[X] ' + StepNames[Index] + ' -- FAILED';
    StepLabels[Index].Font.Color := clRed;
    StepLabels[Index].Font.Style := [fsBold];
  end
  else if Status = 'skip' then
  begin
    StepLabels[Index].Caption := '[--] ' + StepNames[Index] + ' (skipped)';
    StepLabels[Index].Font.Color := clGray;
    StepLabels[Index].Font.Style := [];
  end;
  WizardForm.Refresh();
end;

function GetInstallLogPath(): String;
begin
  Result := AddBackslash(GetEnv('TEMP')) + 'falconpulsar-install.log';
end;

// Append a timestamped line to the install log. Every significant event
// in the installer goes through here so the log is a complete audit trail.
procedure LogInfo(Msg: String);
begin
  if FpLogFile = '' then
    FpLogFile := GetInstallLogPath();
  SaveStringToFile(FpLogFile,
    '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '] [info] ' +
    Msg + #13#10, True);
end;

procedure LogWarn(Msg: String);
begin
  if FpLogFile = '' then
    FpLogFile := GetInstallLogPath();
  SaveStringToFile(FpLogFile,
    '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '] [warn] ' +
    Msg + #13#10, True);
end;

procedure LogError(Msg: String);
begin
  if FpLogFile = '' then
    FpLogFile := GetInstallLogPath();
  SaveStringToFile(FpLogFile,
    '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '] [error] ' +
    Msg + #13#10, True);
end;

procedure LogStep(Msg: String);
begin
  if FpLogFile = '' then
    FpLogFile := GetInstallLogPath();
  SaveStringToFile(FpLogFile, #13#10 +
    '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') +
    '] ==> ' + Msg + #13#10, True);
end;

// Log the machine state: Windows version, build, arch, RAM, user, etc.
procedure LogMachineState();
var
  WinVer: TWindowsVersion;
begin
  GetWindowsVersionEx(WinVer);
  LogStep('Machine state');
  LogInfo('Installer version: {#MyAppVersion}');
  LogInfo('Windows: ' + IntToStr(WinVer.Major) + '.' +
    IntToStr(WinVer.Minor) + ' build ' + IntToStr(WinVer.Build));
  LogInfo('Architecture: ' + GetEnv('PROCESSOR_ARCHITECTURE'));
  LogInfo('Username: ' + GetEnv('USERNAME'));
  LogInfo('Computer: ' + GetEnv('COMPUTERNAME'));
  LogInfo('Temp dir: ' + GetEnv('TEMP'));
  LogInfo('Program Files: ' + ExpandConstant('{pf}'));
  if IsAdmin() then
    LogInfo('Running as Administrator: yes')
  else
    LogWarn('Running as Administrator: no');
end;

// Log the detection results so the log shows what the wizard saw.
procedure LogDetectionResults();
var
  I: Integer;
begin
  LogStep('Environment detection results');
  LogInfo('WSL status: ' + DetectedWslStatus);
  LogInfo('Docker Desktop: ' + DetectedDockerDesktop);
  LogInfo('Distros found: ' + IntToStr(DistroCount));
  for I := 0 to DistroCount - 1 do
  begin
    LogInfo('  [' + IntToStr(I + 1) + '] ' + DistroNames[I] +
      ' | compatible=' + DistroCompatible[I] +
      ' | docker=' + DistroHasDocker[I]);
  end;
  if DistroCount = 0 then
    LogInfo('  (none -- will install fresh ' + '{#WslDistroName}' + ')');
  LogInfo('Auto-selected distro: ' + SelectedDistro);
  if NeedWslInstall then
    LogInfo('WSL install needed: yes')
  else
    LogInfo('WSL install needed: no');
  if NeedDistroInstall then
    LogInfo('Distro install needed: yes')
  else
    LogInfo('Distro install needed: no');
end;

// Read a key=value from the detection file. Returns '' if not found.
function ReadDetectValue(Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line: String;
  EqPos: Integer;
begin
  Result := '';
  if not LoadStringsFromFile(AddBackslash(GetEnv('TEMP')) + 'falconpulsar-detect.txt', Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Lines[I];
    EqPos := Pos('=', Line);
    if EqPos > 0 then
    begin
      if Copy(Line, 1, EqPos - 1) = Key then
      begin
        Result := Copy(Line, EqPos + 1, Length(Line));
        Exit;
      end;
    end;
  end;
end;

// Run the detection helper before wizard pages are shown.
procedure RunDetection();
var
  DetectScript: String;
  ResultCode: Integer;
  I: Integer;
  CountStr: String;
begin
  DetectedWslStatus := 'not-installed';
  DetectedDockerDesktop := 'not-found';
  DistroCount := 0;
  SelectedDistro := '{#WslDistroName}';
  NeedWslInstall := True;
  NeedDistroInstall := True;

  // The detection helper is bundled alongside the installer at build time.
  // At InitializeSetup, {app} is not yet set, but the helper can be run
  // from {tmp} (Inno Setup's temp extraction dir). We extract it first.
  ExtractTemporaryFile('05-detect-environment.ps1');
  ExtractTemporaryFile('lib.ps1');
  DetectScript := ExpandConstant('{tmp}\05-detect-environment.ps1');

  Exec('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -File "' + DetectScript + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Read the results
  DetectedWslStatus := ReadDetectValue('WSL_STATUS');
  DetectedDockerDesktop := ReadDetectValue('DOCKER_DESKTOP');
  CountStr := ReadDetectValue('DISTRO_COUNT');
  if CountStr <> '' then
    DistroCount := StrToIntDef(CountStr, 0);

  if DetectedWslStatus = 'working' then
    NeedWslInstall := False;

  for I := 1 to DistroCount do
  begin
    if I > MAX_DISTROS then Break;
    DistroNames[I - 1] := ReadDetectValue('DISTRO_' + IntToStr(I) + '_NAME');
    DistroCompatible[I - 1] := ReadDetectValue('DISTRO_' + IntToStr(I) + '_COMPATIBLE');
    DistroHasDocker[I - 1] := ReadDetectValue('DISTRO_' + IntToStr(I) + '_DOCKER');
  end;

  // If exactly one compatible distro exists, auto-select it
  if DistroCount = 1 then
  begin
    SelectedDistro := DistroNames[0];
    NeedDistroInstall := False;
  end
  else if DistroCount > 1 then
  begin
    // Default to first compatible distro
    SelectedDistro := '';
    for I := 0 to DistroCount - 1 do
    begin
      if DistroCompatible[I] = 'yes' then
      begin
        SelectedDistro := DistroNames[I];
        NeedDistroInstall := False;
        Break;
      end;
    end;
    if SelectedDistro = '' then
      SelectedDistro := '{#WslDistroName}';
  end;
  // If DistroCount = 0: NeedDistroInstall stays True, SelectedDistro stays default
end;

// Return the distro selected on the Distro Selection page (or auto-selected).
function GetSelectedDistro(): String;
var
  I: Integer;
begin
  // If 0 or 1 distros, the distro page was skipped -- use auto-selected.
  // Don't check radio buttons because they weren't populated (the page
  // was created before detection ran).
  if DistroCount <= 1 then
  begin
    Result := SelectedDistro;
    Exit;
  end;

  // Multi-distro: check radio buttons
  if DistroPage <> nil then
  begin
    for I := 0 to DistroCount - 1 do
    begin
      if (DistroRadios[I] <> nil) and DistroRadios[I].Checked then
      begin
        Result := DistroNames[I];
        NeedDistroInstall := False;
        Exit;
      end;
    end;
    // Last radio = "Install fresh Ubuntu 24.04"
    if (DistroRadios[DistroCount] <> nil) and DistroRadios[DistroCount].Checked then
    begin
      Result := '{#WslDistroName}';
      NeedDistroInstall := True;
      Exit;
    end;
  end;
  Result := SelectedDistro;
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
  LogError('FAILED at: ' + StepName + ' (exit code ' + IntToStr(ExitCode) + ')');
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
  CaptureLog: String;
  CapturedContent: AnsiString;
begin
  // Update the wizard status label so the user sees what's happening
  WizardForm.StatusLabel.Caption := StatusMsg;
  WizardForm.Refresh();

  HelperPath := ExpandConstant('{app}\helpers\') + ScriptName;

  // Capture PowerShell's stdout AND stderr to a per-helper log file.
  // Without this, when a helper exits non-zero we have no idea what
  // happened because Inno Setup's Exec doesn't pipe child output anywhere.
  // We launch via cmd.exe so the > redirection is interpreted by the
  // shell, not PowerShell.
  CaptureLog := AddBackslash(GetEnv('TEMP')) + 'falconpulsar-' + ScriptName + '.out';
  FullArgs := '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + HelperPath + '"';
  if Length(ExtraArgs) > 0 then
    FullArgs := FullArgs + ' ' + ExtraArgs;
  FullArgs := FullArgs + ' > "' + CaptureLog + '" 2>&1';

  LogInfo('Running helper: ' + ScriptName);

  if not Exec(ExpandConstant('{cmd}'), FullArgs,
    ExpandConstant('{app}\helpers'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    LogError('Helper ' + ScriptName + ' failed to launch');
    ShowStepError(StatusMsg, -1);
    Result := False;
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    LogError('Helper ' + ScriptName + ' exited with code ' + IntToStr(ResultCode));
    // Append the captured stdout/stderr to the install log so the user
    // can see what PowerShell printed before dying. Truncated to 4 KB to
    // keep the dialog readable.
    if FileExists(CaptureLog) then
    begin
      if LoadStringFromFile(CaptureLog, CapturedContent) then
      begin
        if Length(CapturedContent) > 4096 then
          CapturedContent := Copy(CapturedContent, Length(CapturedContent) - 4095, 4096);
        LogError('Captured PowerShell output for ' + ScriptName + ':');
        LogError('---begin captured output---');
        LogError(CapturedContent);
        LogError('---end captured output---');
      end;
    end;
    ShowStepError(StatusMsg, ResultCode);
    Result := False;
    Exit;
  end;

  LogInfo('Helper ' + ScriptName + ' completed successfully');
  Result := True;
end;

// ── Install orchestrator ───────────────────────────────────────────────────
// Called by Inno Setup at each install step transition. We hook
// ssPostInstall (after all [Files] are copied to {app}) and run the
// six PowerShell helpers in order. ssInstall fires BEFORE files are
// copied, so the helper scripts would not exist yet on disk.
procedure CurStepChanged(CurStep: TSetupStep);
var
  AdminUserArg: String;
  AdminPassArg: String;
  AppDirArg: String;
  RegistryArg: String;
  RegistryUserArg: String;
  RegistryPassArg: String;
  RegistrySkipArg: String;
  AIGatewayArg: String;
  CookieSecureArg: String;
  Distro: String;
  DistroArg: String;
  DockerExePath: String;
  DockerCheckRC: Integer;
  DockerLive: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    // Log user choices (never log passwords)
    LogStep('Install phase starting');

    Distro := GetSelectedDistro();
    DistroArg := '-Distro "' + Distro + '"';
    AppDirArg := '-InstallDir "' + ExpandConstant('{app}') + '"';

    LogInfo('Selected distro: ' + Distro);
    LogInfo('Install dir: ' + ExpandConstant('{app}'));
    if IsUpgrade then
      LogInfo('Mode: upgrade')
    else
      LogInfo('Mode: fresh install');

    // AI Gateway checkbox
    if WizardIsTaskSelected('aigateway') then
      AIGatewayArg := '-AIGateway "true"'
    else
      AIGatewayArg := '-AIGateway "false"';

    // Front-door HTTPS checkbox. Drives the Secure flag + __Host-
    // prefix on session cookies. Default checked — see [Tasks] above.
    if WizardIsTaskSelected('cookiesecure') then
      CookieSecureArg := '-CookieSecure "true"'
    else
      CookieSecureArg := '-CookieSecure "false"';

    if IsUpgrade and (InstallAction = 'upgrade') then
    begin
      // Admin credentials now come from the credentials page (which is no
      // longer skipped on upgrade), so install.sh can verify them against
      // Core before overwriting the stack. Registry config is unchanged
      // from the existing install and is skipped.
      AdminUserArg := '-AdminUser "' + CredUserEdit.Text + '"';
      AdminPassArg := '-AdminPass "' + CredPassEdit.Text + '"';
      RegistryArg := '-Registry "falconpulsar"';
      RegistryUserArg := '';
      RegistryPassArg := '';
      RegistrySkipArg := '-RegistrySkip';
    end else
    begin
      AdminUserArg := '-AdminUser "' + CredUserEdit.Text + '"';
      AdminPassArg := '-AdminPass "' + CredPassEdit.Text + '"';
      RegistryArg := '-Registry "' + RegistryUrlEdit.Text + '"';
      LogInfo('Registry: ' + RegistryUrlEdit.Text);
      if Length(RegistryUserEdit.Text) > 0 then
      begin
        RegistryUserArg := '-RegistryUser "' + RegistryUserEdit.Text + '"';
        LogInfo('Registry user: ' + RegistryUserEdit.Text);
      end else
        RegistryUserArg := '';
      if Length(RegistryPassEdit.Text) > 0 then
      begin
        RegistryPassArg := '-RegistryPass "' + RegistryPassEdit.Text + '"';
        LogInfo('Registry password: (provided, not logged)');
      end else
        RegistryPassArg := '';
      if RegistrySkipCheck.Checked then
      begin
        RegistrySkipArg := '-RegistrySkip';
        LogInfo('Registry skip: yes');
      end else
        RegistrySkipArg := '';
      LogInfo('Admin user: ' + CredUserEdit.Text);
      LogInfo('Admin password: (provided, not logged)');
    end;

    // If Docker Desktop is installed but not running, prompt the user
    // to start it before proceeding. Docker Desktop provides the Docker
    // engine for WSL distros via its WSL Integration feature -- if it's
    // not running, docker commands inside WSL will fail.
    // Live-check Docker Desktop state (user may have started it since the
    // wizard opened). The cached DetectedDockerDesktop from startup is stale.
    begin
      DockerLive := False;
      DockerExePath := ExpandConstant('{pf}\Docker\Docker\resources\bin\docker.exe');
      if FileExists(DockerExePath) then
      begin
        if Exec(DockerExePath, 'info', '', SW_HIDE, ewWaitUntilTerminated, DockerCheckRC) then
        begin
          if DockerCheckRC = 0 then
          begin
            DockerLive := True;
            LogInfo('Docker Desktop: running (live check at install time)');
          end;
        end;
        if (not DockerLive) then
        begin
          LogWarn('Docker Desktop installed but not responsive at install time');
          if MsgBox(
            'WARNING: Docker Desktop is installed but is not currently running.' + #13#10 + #13#10 +
            'If you use Docker Desktop as your container engine, please start ' +
            'it now and click OK to continue.' + #13#10 + #13#10 +
            'If you want the installer to set up its own Docker Engine inside ' +
            'WSL instead, click OK without starting Docker Desktop.',
            mbError, MB_OKCANCEL) = IDCANCEL then
            Abort;
        end;
      end;
    end;

    CreateChecklist();

    // Step 1: System prerequisites
    UpdateStep(0, 'current');
    LogStep('Step 1/7: System prerequisites');
    if not RunHelper('00-check-prereqs.ps1', '',
        'Checking system prerequisites...') then begin UpdateStep(0, 'fail'); Abort; end;
    UpdateStep(0, 'done');
    LogInfo('Step 1/7: PASSED');

    // Step 2: Enable WSL
    if NeedWslInstall then
    begin
      UpdateStep(1, 'current');
      LogStep('Step 2/7: Enabling WSL2');
      if not RunHelper('10-enable-wsl.ps1', '',
          'Enabling WSL2 (this may take several minutes on first run)...') then begin UpdateStep(1, 'fail'); Abort; end;
      UpdateStep(1, 'done');
      LogInfo('Step 2/7: PASSED');
    end else begin
      UpdateStep(1, 'skip');
      LogInfo('Step 2/7: SKIPPED (WSL already working)');
    end;

    // Step 3: Install distro
    if NeedDistroInstall then
    begin
      UpdateStep(2, 'current');
      LogStep('Step 3/7: Installing ' + Distro);
      if not RunHelper('20-install-distro.ps1', DistroArg,
          'Installing ' + Distro + ' inside WSL...') then begin UpdateStep(2, 'fail'); Abort; end;
      UpdateStep(2, 'done');
      LogInfo('Step 3/7: PASSED');
    end else begin
      UpdateStep(2, 'skip');
      LogInfo('Step 3/7: SKIPPED (using existing distro ' + Distro + ')');
    end;

    // Step 4: Configure systemd
    UpdateStep(3, 'current');
    LogStep('Step 4/7: Configuring systemd');
    if not RunHelper('30-configure-distro.ps1', DistroArg,
        'Configuring systemd inside ' + Distro + '...') then begin UpdateStep(3, 'fail'); Abort; end;
    UpdateStep(3, 'done');
    LogInfo('Step 4/7: PASSED');

    // Step 5: FalconPulsar bash installer
    UpdateStep(4, 'current');
    LogStep('Step 5/7: FalconPulsar bash installer');
    if not RunHelper('40-run-fp-installer.ps1',
        DistroArg + ' ' + AppDirArg + ' ' +
        AdminUserArg + ' ' + AdminPassArg + ' ' +
        RegistryArg + ' ' + RegistryUserArg + ' ' +
        RegistryPassArg + ' ' + RegistrySkipArg + ' ' +
        AIGatewayArg + ' ' + CookieSecureArg + ' ' +
        '-InstallAction "' + InstallAction + '"',
        'Installing FalconPulsar inside WSL (this may take 5-10 minutes)...') then begin UpdateStep(4, 'fail'); Abort; end;
    UpdateStep(4, 'done');
    LogInfo('Step 5/7: PASSED');

    // Step 6: Verify installation health
    UpdateStep(5, 'current');
    LogStep('Step 6/7: Verifying installation');
    if not RunHelper('45-verify-health.ps1', DistroArg,
        'Verifying FalconPulsar containers are running...') then begin UpdateStep(5, 'fail'); Abort; end;
    UpdateStep(5, 'done');
    LogInfo('Step 6/7: PASSED');

    // Step 7: Start Menu shortcuts
    UpdateStep(6, 'current');
    LogStep('Step 7/7: Start Menu shortcuts');
    if not RunHelper('50-register-shortcuts.ps1',
        DistroArg + ' ' + AppDirArg,
        'Registering Start Menu shortcuts...') then begin UpdateStep(6, 'fail'); Abort; end;
    UpdateStep(6, 'done');
    LogInfo('Step 7/7: PASSED');

    // Write tray app config with the selected distro name
    SaveStringToFile(ExpandConstant('{app}\tray-config.txt'), Distro, False);
    LogInfo('Tray config written: ' + Distro);

    LogStep('Installation completed successfully');
    LogInfo('Web UI: http://localhost:8080');
    LogInfo('Log file: ' + FpLogFile);
  end;
end;

// ── Helper: open a URL in the user's default browser ─────────────────────
procedure OpenLegalUrl(Sender: TObject);
var
  Link: TNewStaticText;
  Url: String;
  ResultCode: Integer;
begin
  Link := Sender as TNewStaticText;
  Url := Link.Hint;   // we stash the URL in the Hint property below
  ShellExec('open', Url, '', '', SW_SHOWNORMAL, ewNoWait, ResultCode);
end;

// ── Helper: re-evaluate the legal page Next button based on checkbox ─────
procedure LegalCheckClick(Sender: TObject);
begin
  WizardForm.NextButton.Enabled := LegalCheckBox.Checked;
end;

// Convert a Windows path to a WSL /mnt/... mount path.
// C:\Users\foo\file.txt -> /mnt/c/Users/foo/file.txt
function WinPathToWsl(WinPath: String): String;
var
  S: String;
begin
  S := WinPath;
  if (Length(S) >= 3) and (S[2] = ':') then
    S := '/mnt/' + Lowercase(S[1]) + Copy(S, 3, Length(S));
  StringChangeEx(S, '\', '/', True);
  Result := S;
end;

// Registry page: Test Connection button handler.
// Calls wsl.exe directly (not through a helper script) because {app}
// has not been initialized yet -- the directory selection page comes
// after the registry page. The probe runs `docker manifest inspect`
// inside the WSL distro. If credentials were provided, a `docker login`
// is attempted first using a temp file for the password (never argv).
procedure RegistryTestClick(Sender: TObject);
var
  ResultCode: Integer;
  UrlVal, UserVal, PassVal: String;
  RegHost: String;
  PassFile, WslPassFile: String;
  BashCmd, WslArgs: String;
  Distro: String;
  UseDockerDesktop: Boolean;
  DockerExe: String;
begin
  UrlVal := RegistryUrlEdit.Text;
  UserVal := RegistryUserEdit.Text;
  PassVal := RegistryPassEdit.Text;

  if Length(UrlVal) = 0 then
  begin
    RegistryStatusLabel.Caption := 'Enter a registry URL first.';
    Exit;
  end;

  RegistryStatusLabel.Caption := 'Testing connection to ' + UrlVal + ' ...';
  WizardForm.Refresh();

  // Extract hostname for docker login.
  if Pos('/', UrlVal) > 0 then
    RegHost := Copy(UrlVal, 1, Pos('/', UrlVal) - 1)
  else
    RegHost := 'docker.io';

  // Decide how to run docker: Docker Desktop (native) or WSL distro.
  // Re-detect Docker Desktop state LIVE each time the button is clicked,
  // because the user may have started it since the wizard opened.
  UseDockerDesktop := False;
  DockerExe := ExpandConstant('{pf}\Docker\Docker\resources\bin\docker.exe');
  Distro := GetSelectedDistro();

  if FileExists(DockerExe) then
  begin
    // Live check: is Docker Desktop actually responsive right now?
    if Exec(DockerExe, 'info', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      if ResultCode = 0 then
      begin
        UseDockerDesktop := True;
        LogInfo('Test connection: using Docker Desktop (live check OK)');
      end else
      begin
        RegistryStatusLabel.Caption :=
          'Docker Desktop is installed but not running. Please start Docker ' +
          'Desktop and click Test again, or skip this check.';
        LogInfo('Test connection: Docker Desktop not responsive (exit ' + IntToStr(ResultCode) + ')');
        Exit;
      end;
    end;
  end;

  // No Docker Desktop and no WSL — can't test
  if (not UseDockerDesktop) and (DetectedWslStatus <> 'working') then
  begin
    RegistryStatusLabel.Caption :=
      'Docker is not available yet. The installer will set up WSL + Docker ' +
      'and verify registry access during the install step.';
    Exit;
  end;

  // If credentials provided, login first
  if (Length(UserVal) > 0) and (Length(PassVal) > 0) then
  begin
    PassFile := AddBackslash(GetEnv('TEMP')) + 'fp-reg-pass.tmp';
    SaveStringToFile(PassFile, PassVal, False);

    if UseDockerDesktop then
    begin
      // Native Windows docker login via temp file piped through cmd
      Exec('cmd.exe',
        '/c type "' + PassFile + '" | "' + DockerExe + '" login "' + RegHost +
        '" --username "' + UserVal + '" --password-stdin',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end else
    begin
      WslPassFile := WinPathToWsl(PassFile);
      BashCmd := 'cat "' + WslPassFile + '" | docker login "' + RegHost +
        '" --username "' + UserVal + '" --password-stdin >/dev/null 2>&1';
      WslArgs := '-d ' + Distro + ' -u root -- bash -c "' + BashCmd + '"';
      Exec('wsl.exe', WslArgs, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;

    DeleteFile(PassFile);

    if ResultCode <> 0 then
    begin
      RegistryStatusLabel.Caption :=
        'FAILED: login rejected by ' + RegHost + '. Check credentials.';
      Exit;
    end;
  end;

  // Probe: docker manifest inspect
  if UseDockerDesktop then
  begin
    Exec(DockerExe,
      'manifest inspect "' + UrlVal + '/core:latest"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end else
  begin
    BashCmd := 'DOCKER_CLI_HINTS=false docker manifest inspect "' +
      UrlVal + '/core:latest" >/dev/null 2>&1';
    WslArgs := '-d ' + Distro + ' -u root -- bash -c "' + BashCmd + '"';
    if not Exec('wsl.exe', WslArgs, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      RegistryStatusLabel.Caption :=
        'Docker is not available in ' + Distro + '. ' +
        'The installer will set it up during the install step.';
      Exit;
    end;
  end;

  if ResultCode = 0 then
  begin
    RegistryStatusLabel.Caption := 'OK: connected and images are pullable.';
    LogInfo('Registry test: OK (' + UrlVal + ')');
  end else
  begin
    RegistryStatusLabel.Caption :=
      'FAILED: cannot pull from ' + UrlVal + '. Check URL, credentials, and network.';
    LogWarn('Registry test: FAILED (' + UrlVal + ', exit ' + IntToStr(ResultCode) + ')');
  end;
end;

// Registry page: enable / disable the input fields based on Skip state.
procedure RegistrySkipClick(Sender: TObject);
var
  Enabled: Boolean;
begin
  Enabled := not RegistrySkipCheck.Checked;
  RegistryUrlEdit.Enabled := Enabled;
  RegistryUserEdit.Enabled := Enabled;
  RegistryPassEdit.Enabled := Enabled;
  RegistryTestButton.Enabled := Enabled;
end;

// Create the container registry page.
// New page shown between the legal page and the credentials page. Lets
// the user pick a registry (default: falconpulsar on Docker Hub), enter
// credentials if needed, test the connection, or skip entirely.
// Create the distro selection page. Only shown when 2+ distros are
// registered in WSL. Each distro gets a radio button with a compatibility
// tag. The last option is always "Install a fresh Ubuntu 24.04".
procedure CreateDistroPage();
var
  Y, I: Integer;
  Intro: TNewStaticText;
  Caption: String;
  Tag: String;
begin
  DistroPage := CreateCustomPage(
    LegalPage.ID,
    'Linux Environment',
    'Choose which WSL distribution to use for FalconPulsar');

  Y := 0;

  Intro := TNewStaticText.Create(DistroPage);
  Intro.Parent     := DistroPage.Surface;
  Intro.Top        := Y;
  Intro.Left       := 0;
  Intro.Width      := DistroPage.SurfaceWidth;
  Intro.AutoSize   := False;
  Intro.Height     := ScaleY(36);
  Intro.WordWrap   := True;
  Intro.Caption    :=
    'We found multiple Linux distributions in WSL. Select which one ' +
    'FalconPulsar should use. Docker will be installed automatically ' +
    'if not already present in the selected distribution.';
  Y := Y + Intro.Height + ScaleY(12);

  for I := 0 to DistroCount - 1 do
  begin
    if I >= MAX_DISTROS then Break;

    // Build the caption with compatibility and Docker tags
    Tag := '';
    if DistroCompatible[I] = 'yes' then
      Tag := ' [compatible]'
    else if DistroCompatible[I] = 'no' then
      Tag := ' [not compatible]'
    else
      Tag := ' [unknown]';

    if DistroHasDocker[I] = 'yes' then
      Tag := Tag + ' [Docker installed]';

    Caption := DistroNames[I] + Tag;

    DistroRadios[I] := TNewRadioButton.Create(DistroPage);
    DistroRadios[I].Parent  := DistroPage.Surface;
    DistroRadios[I].Top     := Y;
    DistroRadios[I].Left    := ScaleX(8);
    DistroRadios[I].Width   := DistroPage.SurfaceWidth - ScaleX(16);
    DistroRadios[I].Caption := Caption;

    // Auto-select the first compatible distro
    if (I = 0) or ((DistroCompatible[I] = 'yes') and (not DistroRadios[0].Checked)) then
    begin
      if DistroCompatible[I] = 'yes' then
        DistroRadios[I].Checked := True;
    end;

    Y := Y + ScaleY(22);
  end;

  // "Install fresh" option -- always the last radio button
  DistroRadios[DistroCount] := TNewRadioButton.Create(DistroPage);
  DistroRadios[DistroCount].Parent  := DistroPage.Surface;
  DistroRadios[DistroCount].Top     := Y;
  DistroRadios[DistroCount].Left    := ScaleX(8);
  DistroRadios[DistroCount].Width   := DistroPage.SurfaceWidth - ScaleX(16);
  DistroRadios[DistroCount].Caption := 'Install a fresh Ubuntu 24.04 (recommended)';

  // If no compatible distro was auto-selected, default to fresh install
  if SelectedDistro = '{#WslDistroName}' then
    DistroRadios[DistroCount].Checked := True;
end;

procedure CreateRegistryPage();
var
  Y: Integer;
  Intro: TNewStaticText;
  UrlLabel: TNewStaticText;
  UserLabel: TNewStaticText;
  PassLabel: TNewStaticText;
begin
  RegistryPage := CreateCustomPage(
    DistroPage.ID,
    'Container Registry',
    'Where should FalconPulsar pull images from?');

  Y := 0;

  Intro := TNewStaticText.Create(RegistryPage);
  Intro.Parent     := RegistryPage.Surface;
  Intro.Top        := Y;
  Intro.Left       := 0;
  Intro.Width      := RegistryPage.SurfaceWidth;
  Intro.AutoSize   := False;
  Intro.Height     := ScaleY(36);
  Intro.WordWrap   := True;
  Intro.Caption    :=
    'FalconPulsar can be pulled from any OCI-compliant registry: Docker Hub, ' +
    'GHCR, AWS ECR, Google Artifact Registry, Azure ACR, Quay, Harbor, or a ' +
    'private mirror. Leave the defaults if unsure.';
  Y := Y + Intro.Height + ScaleY(8);

  UrlLabel := TNewStaticText.Create(RegistryPage);
  UrlLabel.Parent  := RegistryPage.Surface;
  UrlLabel.Top     := Y;
  UrlLabel.Left    := 0;
  UrlLabel.Caption := 'Registry (hostname/namespace):';
  Y := Y + UrlLabel.Height + ScaleY(2);

  RegistryUrlEdit := TNewEdit.Create(RegistryPage);
  RegistryUrlEdit.Parent := RegistryPage.Surface;
  RegistryUrlEdit.Top    := Y;
  RegistryUrlEdit.Left   := 0;
  RegistryUrlEdit.Width  := RegistryPage.SurfaceWidth;
  RegistryUrlEdit.Text   := 'falconpulsar';
  Y := Y + RegistryUrlEdit.Height + ScaleY(12);

  UserLabel := TNewStaticText.Create(RegistryPage);
  UserLabel.Parent  := RegistryPage.Surface;
  UserLabel.Top     := Y;
  UserLabel.Left    := 0;
  UserLabel.Caption := 'Username or org name (leave blank for public / anonymous):';
  Y := Y + UserLabel.Height + ScaleY(2);

  RegistryUserEdit := TNewEdit.Create(RegistryPage);
  RegistryUserEdit.Parent := RegistryPage.Surface;
  RegistryUserEdit.Top    := Y;
  RegistryUserEdit.Left   := 0;
  RegistryUserEdit.Width  := RegistryPage.SurfaceWidth;
  Y := Y + RegistryUserEdit.Height + ScaleY(12);

  PassLabel := TNewStaticText.Create(RegistryPage);
  PassLabel.Parent  := RegistryPage.Surface;
  PassLabel.Top     := Y;
  PassLabel.Left    := 0;
  PassLabel.Caption := 'Password or token:';
  Y := Y + PassLabel.Height + ScaleY(2);

  RegistryPassEdit := TNewEdit.Create(RegistryPage);
  RegistryPassEdit.Parent       := RegistryPage.Surface;
  RegistryPassEdit.Top          := Y;
  RegistryPassEdit.Left         := 0;
  RegistryPassEdit.Width        := RegistryPage.SurfaceWidth;
  RegistryPassEdit.PasswordChar := '*';
  Y := Y + RegistryPassEdit.Height + ScaleY(16);

  RegistryTestButton := TNewButton.Create(RegistryPage);
  RegistryTestButton.Parent   := RegistryPage.Surface;
  RegistryTestButton.Top      := Y;
  RegistryTestButton.Left     := 0;
  RegistryTestButton.Width    := ScaleX(140);
  RegistryTestButton.Height   := ScaleY(25);
  RegistryTestButton.Caption  := 'Test connection';
  RegistryTestButton.OnClick  := @RegistryTestClick;
  Y := Y + RegistryTestButton.Height + ScaleY(8);

  RegistryStatusLabel := TNewStaticText.Create(RegistryPage);
  RegistryStatusLabel.Parent   := RegistryPage.Surface;
  RegistryStatusLabel.Top      := Y;
  RegistryStatusLabel.Left     := 0;
  RegistryStatusLabel.Width    := RegistryPage.SurfaceWidth;
  RegistryStatusLabel.AutoSize := False;
  RegistryStatusLabel.Height   := ScaleY(18);
  RegistryStatusLabel.Caption  := '';
  Y := Y + RegistryStatusLabel.Height + ScaleY(16);

  RegistrySkipCheck := TNewCheckBox.Create(RegistryPage);
  RegistrySkipCheck.Parent  := RegistryPage.Surface;
  RegistrySkipCheck.Top     := Y;
  RegistrySkipCheck.Left    := 0;
  RegistrySkipCheck.Width   := RegistryPage.SurfaceWidth;
  RegistrySkipCheck.Caption := 'Skip the registry check (I already have docker login configured)';
  RegistrySkipCheck.OnClick := @RegistrySkipClick;
end;

// ── Helper: add a single legal-document link to the legal page ───────────
// Hoisted out of CreateLegalPage because Inno Setup's Pascal Script does
// not support nested procedures.
procedure AddLegalLink(Caption, Url: String; var Y: Integer);
var
  Link: TNewStaticText;
begin
  Link := TNewStaticText.Create(LegalPage);
  Link.Parent     := LegalPage.Surface;
  Link.Left       := ScaleX(20);
  Link.Top        := Y;
  Link.Width      := LegalPage.SurfaceWidth - ScaleX(40);
  Link.Caption    := '• ' + Caption + '   (' + Url + ')';
  Link.Hint       := Url;
  Link.ShowHint   := False;
  Link.Cursor     := crHand;
  Link.Font.Color := clBlue;
  Link.Font.Style := [fsUnderline];
  Link.OnClick    := @OpenLegalUrl;
  Y := Y + ScaleY(22);
end;

// ── Existing-install detection + custom wizard page ─────────────────────
// Matches the macOS SwiftUI installer's "Existing Installation Detected"
// page. Invokes 06-detect-existing-install.ps1 to probe BOTH Windows-side
// state and WSL-side state (containers, images, volumes, data dir, etc.),
// then presents an inventory + 3-way radio: Upgrade / Reinstall / Fresh.
// Fresh requires typing DELETE to confirm.

function GetExistingSentinelPath(): String;
begin
  Result := AddBackslash(GetEnv('TEMP')) + 'falconpulsar-existing.txt';
end;

// Parse one KEY=VALUE line from the sentinel file. Returns empty string
// if the key isn't present.
function SentinelGet(Content: String; Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line, Prefix: String;
begin
  Result := '';
  Lines := [];
  // Normalise line endings. StringChangeEx mutates Content by reference
  // and returns an Integer (count of replacements) -- don't assign.
  StringChangeEx(Content, #13#10, #10, True);
  StringChangeEx(Content, #13,    #10, True);
  Line := '';
  for I := 1 to Length(Content) do
  begin
    if Content[I] = #10 then
    begin
      SetArrayLength(Lines, GetArrayLength(Lines) + 1);
      Lines[GetArrayLength(Lines) - 1] := Line;
      Line := '';
    end else
      Line := Line + Content[I];
  end;
  if Line <> '' then
  begin
    SetArrayLength(Lines, GetArrayLength(Lines) + 1);
    Lines[GetArrayLength(Lines) - 1] := Line;
  end;

  Prefix := Key + '=';
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Copy(Lines[I], 1, Length(Prefix)) = Prefix then
    begin
      Result := Copy(Lines[I], Length(Prefix) + 1, Length(Lines[I]));
      Exit;
    end;
  end;
end;

// Run 06-detect-existing-install.ps1 synchronously. The helper writes
// its results to %TEMP%\falconpulsar-existing.txt (a simple key=value
// text file). We parse that into global Pascal vars.
procedure RunExistingInstallDetection();
var
  HelperPath: String;
  Args: String;
  RC: Integer;
  Sentinel: String;
  Content: AnsiString;
  WslStackPath: String;
begin
  ExistingDetectionDone := False;
  ExistingHasPrior      := False;
  ExistingHasData       := False;
  ExistingHasContainers := False;
  ExistingHasImages     := False;
  ExistingInventoryText := '';

  // Extract to temp so we can run before {app} exists.
  ExtractTemporaryFile('lib.ps1');
  ExtractTemporaryFile('06-detect-existing-install.ps1');
  HelperPath := ExpandConstant('{tmp}\06-detect-existing-install.ps1');

  Args := '-NoProfile -ExecutionPolicy Bypass -File "' + HelperPath + '"';
  if Length(SelectedDistro) > 0 then
    Args := Args + ' -Distro "' + SelectedDistro + '"';

  LogInfo('Running existing-install detection...');
  if not Exec('powershell.exe', Args,
              ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, RC) then
  begin
    LogWarn('Could not launch 06-detect-existing-install.ps1');
    Exit;
  end;
  if RC <> 0 then
    LogWarn('06-detect-existing-install.ps1 exited with code ' + IntToStr(RC) + ' (continuing anyway)');

  Sentinel := GetExistingSentinelPath();
  if not FileExists(Sentinel) then
  begin
    LogWarn('Existing-install sentinel not found at ' + Sentinel);
    Exit;
  end;

  if not LoadStringFromFile(Sentinel, Content) then
  begin
    LogWarn('Could not read existing-install sentinel');
    Exit;
  end;

  ExistingDetectionDone := True;
  ExistingHasPrior      := (SentinelGet(Content, 'HasPrior') = 'yes');
  ExistingHasData       := (SentinelGet(Content, 'WslData')  = 'yes');
  ExistingHasContainers := (StrToIntDef(SentinelGet(Content, 'Containers'), 0) > 0);
  ExistingHasImages     := (StrToIntDef(SentinelGet(Content, 'Images'),     0) > 0);

  // Build the multi-line inventory shown on the wizard page.
  // WslHomeDir is the actual resolved stack path emitted by
  // 06-detect-existing-install.ps1 (either /home/<user>/falconpulsar for
  // per-user installs or /home/falconpulsar for legacy service-user ones).
  ExistingInventoryText := '';
  WslStackPath := SentinelGet(Content, 'WslHomeDir');
  if WslStackPath = '' then WslStackPath := '/home/falconpulsar';
  if SentinelGet(Content, 'WslHome') = 'yes' then
  begin
    ExistingInventoryText := ExistingInventoryText + '  * WSL stack directory: ' + WslStackPath;
    if SentinelGet(Content, 'WslHomeSize') <> '' then
      ExistingInventoryText := ExistingInventoryText + ' (' + SentinelGet(Content, 'WslHomeSize') + ')';
    ExistingInventoryText := ExistingInventoryText + #13#10;
  end;
  if SentinelGet(Content, 'WslData') = 'yes' then
  begin
    ExistingInventoryText := ExistingInventoryText + '  * Database (WSL): ' + WslStackPath + '/data';
    if SentinelGet(Content, 'WslDataSize') <> '' then
      ExistingInventoryText := ExistingInventoryText + ' (' + SentinelGet(Content, 'WslDataSize') + ')  -- PRESERVED unless you choose Fresh';
    ExistingInventoryText := ExistingInventoryText + #13#10;
  end;
  if StrToIntDef(SentinelGet(Content, 'Containers'), 0) > 0 then
  begin
    ExistingInventoryText := ExistingInventoryText + '  * Docker containers: ' +
      SentinelGet(Content, 'Containers') + ' (' +
      SentinelGet(Content, 'ContainersRun') + ' running)' + #13#10;
  end;
  if StrToIntDef(SentinelGet(Content, 'Images'), 0) > 0 then
    ExistingInventoryText := ExistingInventoryText +
      '  * Cached Docker images: ' + SentinelGet(Content, 'Images') + #13#10;
  if StrToIntDef(SentinelGet(Content, 'Networks'), 0) > 0 then
    ExistingInventoryText := ExistingInventoryText +
      '  * Docker networks: ' + SentinelGet(Content, 'Networks') + #13#10;
  if StrToIntDef(SentinelGet(Content, 'Volumes'), 0) > 0 then
    ExistingInventoryText := ExistingInventoryText +
      '  * Docker named volumes: ' + SentinelGet(Content, 'Volumes') + #13#10;
  if SentinelGet(Content, 'WinEnv') = 'yes' then
    ExistingInventoryText := ExistingInventoryText +
      '  * Windows-side .env mirror: ' + GetEnv('USERPROFILE') + '\falconpulsar\.env' + #13#10;
  if SentinelGet(Content, 'FpExe') = 'yes' then
    ExistingInventoryText := ExistingInventoryText +
      '  * fp console launcher: installed' + #13#10;
  if SentinelGet(Content, 'InnoKey') = 'yes' then
    ExistingInventoryText := ExistingInventoryText +
      '  * Registered with Windows Add/Remove Programs' + #13#10;

  if ExistingInventoryText = '' then
    ExistingInventoryText := '  (nothing detected)';

  if ExistingHasPrior then
    LogInfo('Existing-install detection complete: prior state found')
  else
    LogInfo('Existing-install detection complete: clean machine');

  // Keep legacy IsUpgrade flag in sync so other code paths stay correct.
  IsUpgrade := ExistingHasPrior;
end;

procedure ExistingRadioChanged(Sender: TObject); forward;
procedure LayoutExistingPage(); forward;

// Declared outside of the creation procedure so LayoutExistingPage can reach it.
var
  ExistingIntroLabel: TNewStaticText;

procedure CreateExistingInstallPage();
begin
  ExistingPage := CreateCustomPage(
    wpWelcome,
    'Existing Installation',
    'We found a prior FalconPulsar install on this machine');

  // Intro — 2 lines is plenty (we know the title says "prior install").
  ExistingIntroLabel := TNewStaticText.Create(ExistingPage);
  ExistingIntroLabel.Parent  := ExistingPage.Surface;
  ExistingIntroLabel.Left    := ScaleX(8);
  ExistingIntroLabel.Top     := ScaleY(4);
  ExistingIntroLabel.Width   := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingIntroLabel.AutoSize := False;
  ExistingIntroLabel.Height  := ScaleY(24);
  ExistingIntroLabel.WordWrap := True;
  ExistingIntroLabel.Caption :=
    'We detected the following state from a previous install. Choose how to proceed.';

  // Inventory: height is set dynamically by LayoutExistingPage based on
  // how many lines the detector found. Shown in monospace for alignment.
  ExistingInventoryLabel := TNewStaticText.Create(ExistingPage);
  ExistingInventoryLabel.Parent   := ExistingPage.Surface;
  ExistingInventoryLabel.Left     := ScaleX(8);
  ExistingInventoryLabel.Width    := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingInventoryLabel.AutoSize := False;
  ExistingInventoryLabel.WordWrap := False;
  ExistingInventoryLabel.Font.Name := 'Consolas';
  ExistingInventoryLabel.Font.Size := 8;
  ExistingInventoryLabel.Caption  := '  (scanning...)';

  ExistingUpgradeRadio := TNewRadioButton.Create(ExistingPage);
  ExistingUpgradeRadio.Parent  := ExistingPage.Surface;
  ExistingUpgradeRadio.Left    := ScaleX(8);
  ExistingUpgradeRadio.Width   := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingUpgradeRadio.Height  := ScaleY(17);
  ExistingUpgradeRadio.Caption := 'Upgrade in place -- pull latest images, keep data and settings';
  ExistingUpgradeRadio.Checked := True;
  ExistingUpgradeRadio.OnClick := @ExistingRadioChanged;

  ExistingReinstallRadio := TNewRadioButton.Create(ExistingPage);
  ExistingReinstallRadio.Parent  := ExistingPage.Surface;
  ExistingReinstallRadio.Left    := ScaleX(8);
  ExistingReinstallRadio.Width   := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingReinstallRadio.Height  := ScaleY(17);
  ExistingReinstallRadio.Caption := 'Reinstall (keep data) -- recreate stack files, preserve database';
  ExistingReinstallRadio.OnClick := @ExistingRadioChanged;

  ExistingFreshRadio := TNewRadioButton.Create(ExistingPage);
  ExistingFreshRadio.Parent  := ExistingPage.Surface;
  ExistingFreshRadio.Left    := ScaleX(8);
  ExistingFreshRadio.Width   := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingFreshRadio.Height  := ScaleY(17);
  ExistingFreshRadio.Caption := 'Fresh install -- DELETE ALL DATA (containers, images, volumes, database)';
  ExistingFreshRadio.Font.Color := $0000A0;
  ExistingFreshRadio.OnClick := @ExistingRadioChanged;

  ExistingFreshWarnLabel := TNewStaticText.Create(ExistingPage);
  ExistingFreshWarnLabel.Parent := ExistingPage.Surface;
  ExistingFreshWarnLabel.Left   := ScaleX(28);
  ExistingFreshWarnLabel.Width  := ExistingPage.SurfaceWidth - ScaleX(36);
  ExistingFreshWarnLabel.AutoSize := False;
  ExistingFreshWarnLabel.Height := ScaleY(16);
  ExistingFreshWarnLabel.WordWrap := True;
  ExistingFreshWarnLabel.Font.Style := [fsBold];
  ExistingFreshWarnLabel.Font.Color := $0000A0;
  ExistingFreshWarnLabel.Visible := False;
  ExistingFreshWarnLabel.Caption := 'This is irreversible. Your time-series database will be lost.';

  ExistingFreshConfirmLabel := TNewStaticText.Create(ExistingPage);
  ExistingFreshConfirmLabel.Parent := ExistingPage.Surface;
  ExistingFreshConfirmLabel.Left   := ScaleX(28);
  ExistingFreshConfirmLabel.Width  := ExistingPage.SurfaceWidth - ScaleX(36);
  ExistingFreshConfirmLabel.AutoSize := False;
  ExistingFreshConfirmLabel.Height := ScaleY(16);
  ExistingFreshConfirmLabel.Visible := False;
  ExistingFreshConfirmLabel.Caption := 'Type DELETE (uppercase) to confirm:';

  ExistingFreshConfirmEdit := TNewEdit.Create(ExistingPage);
  ExistingFreshConfirmEdit.Parent := ExistingPage.Surface;
  ExistingFreshConfirmEdit.Left   := ScaleX(28);
  ExistingFreshConfirmEdit.Width  := ScaleX(140);
  ExistingFreshConfirmEdit.Visible := False;

  ExistingRemoveImagesCheck := TNewCheckBox.Create(ExistingPage);
  ExistingRemoveImagesCheck.Parent := ExistingPage.Surface;
  ExistingRemoveImagesCheck.Left   := ScaleX(8);
  ExistingRemoveImagesCheck.Width  := ExistingPage.SurfaceWidth - ScaleX(16);
  ExistingRemoveImagesCheck.Height := ScaleY(17);
  ExistingRemoveImagesCheck.Caption := 'Also remove cached Docker images (slows first re-enable; recommended for fresh)';
  ExistingRemoveImagesCheck.Checked := False;

  // Initial layout pass; real content arrives via CurPageChanged -> LayoutExistingPage.
  LayoutExistingPage();
end;

// Count how many newline-separated rows the inventory label's caption has,
// so the inventory box height tracks the content. Falls back to 1 for empty.
function InventoryLineCount(): Integer;
var
  I: Integer;
  S: String;
begin
  Result := 1;
  S := ExistingInventoryLabel.Caption;
  for I := 1 to Length(S) do
    if S[I] = #10 then
      Result := Result + 1;
  if Result < 1 then Result := 1;
  if Result > 6 then Result := 6;   // hard cap so radios never get pushed off-screen
end;

// Dynamic layout — called from CurPageChanged (once) and ExistingRadioChanged
// (every time the user flips a radio). Repositions everything based on:
//   * how many inventory lines we have (1 line vs 7 lines makes a big
//     difference in vertical usage)
//   * which action is selected (Fresh exposes 3 extra controls;
//     Upgrade hides the "remove images" checkbox entirely).
// Keeps the entire page inside the default ~275 px Inno Setup surface.
procedure LayoutExistingPage();
var
  Y, InvH, Gap: Integer;
  IsFresh: Boolean;
begin
  if ExistingPage = nil then Exit;

  Y := ExistingIntroLabel.Top + ExistingIntroLabel.Height + ScaleY(4);
  InvH := InventoryLineCount() * ScaleY(14);   // ~14 px per Consolas row at 8pt
  ExistingInventoryLabel.Top    := Y;
  ExistingInventoryLabel.Height := InvH;
  Y := Y + InvH + ScaleY(6);

  Gap := ScaleY(4);
  ExistingUpgradeRadio.Top   := Y;   Y := Y + ExistingUpgradeRadio.Height   + Gap;
  ExistingReinstallRadio.Top := Y;   Y := Y + ExistingReinstallRadio.Height + Gap;
  ExistingFreshRadio.Top     := Y;   Y := Y + ExistingFreshRadio.Height     + Gap;

  IsFresh := ExistingFreshRadio.Checked;

  if IsFresh then
  begin
    Y := Y + ScaleY(2);
    ExistingFreshWarnLabel.Top := Y;
    ExistingFreshWarnLabel.Visible := True;
    Y := Y + ExistingFreshWarnLabel.Height + ScaleY(2);

    ExistingFreshConfirmLabel.Top := Y;
    ExistingFreshConfirmLabel.Visible := True;
    Y := Y + ExistingFreshConfirmLabel.Height + ScaleY(2);

    ExistingFreshConfirmEdit.Top := Y;
    ExistingFreshConfirmEdit.Visible := True;
    Y := Y + ExistingFreshConfirmEdit.Height + ScaleY(6);
  end else
  begin
    ExistingFreshWarnLabel.Visible    := False;
    ExistingFreshConfirmLabel.Visible := False;
    ExistingFreshConfirmEdit.Visible  := False;
  end;

  // "Also remove cached Docker images" is only meaningful for Fresh or
  // Reinstall. On Upgrade the whole point is to keep images around.
  if ExistingUpgradeRadio.Checked then
  begin
    ExistingRemoveImagesCheck.Visible := False;
  end else
  begin
    ExistingRemoveImagesCheck.Top := Y;
    ExistingRemoveImagesCheck.Visible := True;
  end;
end;

procedure ExistingRadioChanged(Sender: TObject);
begin
  // Auto-check "remove cached images" when user picks Fresh — matches the
  // default behaviour of the macOS SwiftUI installer.
  if ExistingFreshRadio.Checked then
    ExistingRemoveImagesCheck.Checked := True;
  LayoutExistingPage();
end;

// ── Build the custom legal acknowledgement page ──────────────────────────
procedure CreateLegalPage();
var
  IntroLabel: TNewStaticText;
  Y: Integer;
begin
  LegalPage := CreateCustomPage(
    wpWelcome,
    'Before you install',
    'Please review and accept the FalconPulsar legal terms');

  IntroLabel := TNewStaticText.Create(LegalPage);
  IntroLabel.Parent  := LegalPage.Surface;
  IntroLabel.Left    := ScaleX(20);
  IntroLabel.Top     := ScaleY(8);
  IntroLabel.Width   := LegalPage.SurfaceWidth - ScaleX(40);
  IntroLabel.AutoSize := False;
  IntroLabel.Height  := ScaleY(60);
  IntroLabel.WordWrap := True;
  IntroLabel.Caption :=
    'By installing FalconPulsar, you confirm you have read and agree to ' +
    'all four documents below. Click each link to open it in your default ' +
    'browser. You must check the box at the bottom to continue.';

  Y := ScaleY(80);
  AddLegalLink('Terms of Service',      'https://falconpulsar.com/terms/',   Y);
  AddLegalLink('Privacy Policy',        'https://falconpulsar.com/privacy/', Y);
  AddLegalLink('Acceptable Use Policy', 'https://falconpulsar.com/aup/',     Y);
  AddLegalLink('Security Policy',       'https://falconpulsar.com/security/', Y);

  LegalCheckBox := TNewCheckBox.Create(LegalPage);
  LegalCheckBox.Parent   := LegalPage.Surface;
  LegalCheckBox.Left     := ScaleX(20);
  LegalCheckBox.Top      := Y + ScaleY(20);
  LegalCheckBox.Width    := LegalPage.SurfaceWidth - ScaleX(40);
  LegalCheckBox.Height   := ScaleY(24);
  LegalCheckBox.Caption  := 'I have read and agree to all four documents';
  LegalCheckBox.Checked  := False;
  LegalCheckBox.OnClick  := @LegalCheckClick;
end;

// Called by Inno Setup whenever the wizard switches to a new page. We use
// this to gate the Next button on the legal page based on the checkbox
// state.
procedure CurPageChanged(CurPageID: Integer);
var
  Summary: String;
  I: Integer;
  Tag: String;
begin
  // Welcome page: run detection the first time it's displayed.
  // This runs AFTER the form is visible, so the user sees
  // "Detecting your environment..." while detection runs.
  if (CurPageID = wpWelcome) and (not DetectionDone) then
  begin
    DetectionDone := True;
    WizardForm.Refresh();

    LogStep('Running environment detection');
    RunDetection();
    LogDetectionResults();

    // Update the Welcome text with detection results
    Summary :=
      'Version {#MyAppVersion}' + #13#10 +
      'Self-host in 3 minutes. Your infrastructure, your data.' + #13#10 +
      'https://falconpulsar.com' + #13#10 +
      '(c) 2026 {#MyAppPublisher}. GNU AGPL v3 License.' + #13#10 + #13#10 +
      'Your environment:' + #13#10;
    if DetectedWslStatus = 'working' then
      Summary := Summary + '  WSL2: detected' + #13#10
    else
      Summary := Summary + '  WSL2: will be installed' + #13#10;
    if DistroCount > 0 then
      Summary := Summary + '  Linux: ' + DistroNames[0] + ' found' + #13#10
    else
      Summary := Summary + '  Linux: Ubuntu 24.04 will be installed' + #13#10;
    if DetectedDockerDesktop = 'running' then
      Summary := Summary + '  Docker: Docker Desktop running' + #13#10
    else if DetectedDockerDesktop = 'installed' then
      Summary := Summary + '  Docker: Docker Desktop installed (start it)' + #13#10
    else
      Summary := Summary + '  Docker: will be installed inside WSL' + #13#10;
    Summary := Summary + #13#10 +
      'This installer will set up:' + #13#10 +
      '  - Core engine (REST API + WebSocket)' + #13#10 +
      '  - Web UI for dashboards and operations' + #13#10 +
      '  - AI Capabilities for natural-language interaction' + #13#10 + #13#10 +
      'Click Next to continue.';
    WizardForm.WelcomeLabel2.Caption := Summary;

    // Now that detection is done, populate the distro page radio buttons.
    // The page was created empty in InitializeWizard; we fill it now.
    if DistroCount >= 2 then
    begin
      for I := 0 to DistroCount - 1 do
      begin
        if I >= MAX_DISTROS then Break;
        Tag := '';
        if DistroCompatible[I] = 'yes' then
          Tag := ' [compatible]'
        else if DistroCompatible[I] = 'no' then
          Tag := ' [not compatible]'
        else
          Tag := ' [unknown]';
        if DistroHasDocker[I] = 'yes' then
          Tag := Tag + ' [Docker installed]';
        if DistroRadios[I] <> nil then
        begin
          DistroRadios[I].Caption := DistroNames[I] + Tag;
          DistroRadios[I].Visible := True;
          if DistroCompatible[I] = 'yes' then
            DistroRadios[I].Checked := True;
        end;
      end;
    end;
  end;

  // Legal page: gate Next button on checkbox
  if (LegalPage <> nil) and (CurPageID = LegalPage.ID) then
    WizardForm.NextButton.Enabled := LegalCheckBox.Checked;

  // Existing-install page: populate the inventory label from the
  // detection we ran in InitializeWizard, then lay the page out based
  // on how many inventory lines we have + which action is selected.
  if (ExistingPage <> nil) and (CurPageID = ExistingPage.ID) then
  begin
    if ExistingInventoryText <> '' then
      ExistingInventoryLabel.Caption := ExistingInventoryText
    else
      ExistingInventoryLabel.Caption := '  (nothing detected)';
    // Default to Upgrade if there's a real prior install; else Fresh.
    if ExistingHasPrior then
      ExistingUpgradeRadio.Checked := True
    else
      ExistingFreshRadio.Checked := True;
    LayoutExistingPage();
  end;
end;

// Password strength assessment: returns Weak / Medium / Strong.
function GetPasswordStrength(Pass: String): String;
var
  HasUpper, HasLower, HasDigit, HasSymbol: Boolean;
  Classes: Integer;
  I: Integer;
  C: Char;
begin
  HasUpper := False;
  HasLower := False;
  HasDigit := False;
  HasSymbol := False;

  for I := 1 to Length(Pass) do
  begin
    C := Pass[I];
    if (C >= 'A') and (C <= 'Z') then HasUpper := True
    else if (C >= 'a') and (C <= 'z') then HasLower := True
    else if (C >= '0') and (C <= '9') then HasDigit := True
    else HasSymbol := True;
  end;

  Classes := 0;
  if HasUpper then Classes := Classes + 1;
  if HasLower then Classes := Classes + 1;
  if HasDigit then Classes := Classes + 1;
  if HasSymbol then Classes := Classes + 1;

  if (Length(Pass) < 10) or (Classes <= 1) then
    Result := 'Weak'
  else if (Length(Pass) >= 12) and (Classes >= 3) then
    Result := 'Strong'
  else
    Result := 'Medium';
end;

// Update the strength label when the password field changes.
procedure CredPassChange(Sender: TObject);
var
  Strength: String;
  Len: Integer;
begin
  Len := Length(CredPassEdit.Text);
  Strength := GetPasswordStrength(CredPassEdit.Text);

  // Update character count
  if CredCharCountLabel <> nil then
  begin
    if Len < 10 then
      CredCharCountLabel.Caption := IntToStr(Len) + '/10 characters (minimum 10)'
    else
      CredCharCountLabel.Caption := IntToStr(Len) + ' characters';
  end;

  // Update strength bar + label
  if Len = 0 then
  begin
    CredStrengthLabel.Caption := '';
    CredStrengthLabel.Font.Color := clWindowText;
  end else
  begin
    CredStrengthLabel.Caption := 'Password strength: ' + Strength;
    if Strength = 'Weak' then
      CredStrengthLabel.Font.Color := clRed
    else if Strength = 'Medium' then
      CredStrengthLabel.Font.Color := $0080FF
    else
      CredStrengthLabel.Font.Color := clGreen;
  end;
end;

// Generate a random password: 20 chars, mix of upper/lower/digit/symbol.
procedure CredGenerateClick(Sender: TObject);
var
  Chars: String;
  Pass: String;
  I: Integer;
begin
  Chars := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%&*-_=+';
  Pass := '';
  for I := 1 to 20 do
    Pass := Pass + Chars[Random(Length(Chars)) + 1];
  CredPassEdit.Text := Pass;
  CredConfirmEdit.Text := Pass;
  CredPassEdit.PasswordChar := #0;
  CredGeneratedLabel.Text := Pass;
  CredGeneratedLabel.Visible := True;
  CredGeneratedCaption.Visible := True;
  CredStrengthLabel.Caption := 'Password strength: Strong (auto-generated)';
  CredStrengthLabel.Font.Color := clGreen;
  if CredCharCountLabel <> nil then CredCharCountLabel.Caption := '20 characters';
  LogInfo('Admin password: auto-generated (20 chars)');
end;

// Copy the current password to the clipboard via clip.exe.
procedure CredCopyClick(Sender: TObject);
var
  PassFile: String;
  ResultCode: Integer;
begin
  if Length(CredPassEdit.Text) = 0 then Exit;
  PassFile := AddBackslash(GetEnv('TEMP')) + 'fp-pass-copy.tmp';
  SaveStringToFile(PassFile, CredPassEdit.Text, False);
  Exec('cmd.exe', '/c type "' + PassFile + '" | clip', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  DeleteFile(PassFile);
  CredStrengthLabel.Caption := CredStrengthLabel.Caption + '  (copied!)';
end;

// Create the credentials page as a fully custom TWizardPage.
procedure CreateCredentialsPage();
var
  Y: Integer;
  Intro: TNewStaticText;
  UserLabel: TNewStaticText;
  PassLabel: TNewStaticText;
  ConfirmLabel: TNewStaticText;
  ReqLabel: TNewStaticText;
  GenButton: TNewButton;
begin
  CredentialsPage := CreateCustomPage(
    RegistryPage.ID,
    'FalconPulsar Admin Credentials',
    'Set the administrator account for the Web UI');

  Y := 0;

  Intro := TNewStaticText.Create(CredentialsPage);
  Intro.Parent     := CredentialsPage.Surface;
  Intro.Top        := Y;
  Intro.Left       := 0;
  Intro.Width      := CredentialsPage.SurfaceWidth;
  Intro.AutoSize   := False;
  Intro.Height     := ScaleY(30);
  Intro.WordWrap   := True;
  Intro.Caption    :=
    'The password is NOT stored on disk. It is used once to create the admin ' +
    'user and then exchanged for a service token. Save it now.';
  Y := Y + Intro.Height + ScaleY(8);

  // Username
  UserLabel := TNewStaticText.Create(CredentialsPage);
  UserLabel.Parent  := CredentialsPage.Surface;
  UserLabel.Top     := Y;
  UserLabel.Left    := 0;
  UserLabel.Caption := 'Admin username:';
  Y := Y + UserLabel.Height + ScaleY(2);

  CredUserEdit := TNewEdit.Create(CredentialsPage);
  CredUserEdit.Parent := CredentialsPage.Surface;
  CredUserEdit.Top    := Y;
  CredUserEdit.Left   := 0;
  CredUserEdit.Width  := CredentialsPage.SurfaceWidth;
  CredUserEdit.Text   := 'admin';
  Y := Y + CredUserEdit.Height + ScaleY(10);

  // Password
  PassLabel := TNewStaticText.Create(CredentialsPage);
  PassLabel.Parent  := CredentialsPage.Surface;
  PassLabel.Top     := Y;
  PassLabel.Left    := 0;
  PassLabel.Caption := 'Admin password:';
  Y := Y + PassLabel.Height + ScaleY(2);

  CredPassEdit := TNewEdit.Create(CredentialsPage);
  CredPassEdit.Parent       := CredentialsPage.Surface;
  CredPassEdit.Top          := Y;
  CredPassEdit.Left         := 0;
  CredPassEdit.Width        := CredentialsPage.SurfaceWidth - ScaleX(55);
  CredPassEdit.PasswordChar := '*';
  CredPassEdit.OnChange     := @CredPassChange;

  // Copy button right next to the password field
  CopyButton := TNewButton.Create(CredentialsPage);
  CopyButton.Parent  := CredentialsPage.Surface;
  CopyButton.Top     := Y;
  CopyButton.Left    := CredentialsPage.SurfaceWidth - ScaleX(50);
  CopyButton.Width   := ScaleX(50);
  CopyButton.Height  := CredPassEdit.Height;
  CopyButton.Caption := 'Copy';
  CopyButton.OnClick := @CredCopyClick;
  Y := Y + CredPassEdit.Height + ScaleY(10);

  // Confirm password
  ConfirmLabel := TNewStaticText.Create(CredentialsPage);
  ConfirmLabel.Parent  := CredentialsPage.Surface;
  ConfirmLabel.Top     := Y;
  ConfirmLabel.Left    := 0;
  ConfirmLabel.Caption := 'Confirm password:';
  Y := Y + ConfirmLabel.Height + ScaleY(2);

  CredConfirmEdit := TNewEdit.Create(CredentialsPage);
  CredConfirmEdit.Parent       := CredentialsPage.Surface;
  CredConfirmEdit.Top          := Y;
  CredConfirmEdit.Left         := 0;
  CredConfirmEdit.Width        := CredentialsPage.SurfaceWidth;
  CredConfirmEdit.PasswordChar := '*';
  Y := Y + CredConfirmEdit.Height + ScaleY(6);

  // Strength text + character count on same line
  CredStrengthLabel := TNewStaticText.Create(CredentialsPage);
  CredStrengthLabel.Parent   := CredentialsPage.Surface;
  CredStrengthLabel.Top      := Y;
  CredStrengthLabel.Left     := 0;
  CredStrengthLabel.Width    := ScaleX(200);
  CredStrengthLabel.AutoSize := False;
  CredStrengthLabel.Height   := ScaleY(16);
  CredStrengthLabel.Caption  := '';

  CredCharCountLabel := TNewStaticText.Create(CredentialsPage);
  CredCharCountLabel.Parent    := CredentialsPage.Surface;
  CredCharCountLabel.Top       := Y;
  CredCharCountLabel.Left      := ScaleX(210);
  CredCharCountLabel.Width     := CredentialsPage.SurfaceWidth - ScaleX(210);
  CredCharCountLabel.AutoSize  := False;
  CredCharCountLabel.Height    := ScaleY(16);
  CredCharCountLabel.Caption   := '0/10 characters (minimum 10)';
  CredCharCountLabel.Font.Color := clGray;
  Y := Y + CredStrengthLabel.Height + ScaleY(4);

  // Requirements text
  ReqLabel := TNewStaticText.Create(CredentialsPage);
  ReqLabel.Parent   := CredentialsPage.Surface;
  ReqLabel.Top      := Y;
  ReqLabel.Left     := 0;
  ReqLabel.Width    := CredentialsPage.SurfaceWidth;
  ReqLabel.AutoSize := False;
  ReqLabel.Height   := ScaleY(16);
  ReqLabel.Caption  := 'Use uppercase, lowercase, numbers, and symbols for a strong password.';
  ReqLabel.Font.Color := clGray;
  Y := Y + ReqLabel.Height + ScaleY(10);

  // Generate button only (copy is next to the generated field below)
  GenButton := TNewButton.Create(CredentialsPage);
  GenButton.Parent  := CredentialsPage.Surface;
  GenButton.Top     := Y;
  GenButton.Left    := 0;
  GenButton.Width   := ScaleX(180);
  GenButton.Height  := ScaleY(25);
  GenButton.Caption := 'Generate strong password';
  GenButton.OnClick := @CredGenerateClick;
  Y := Y + GenButton.Height + ScaleY(8);

  // Generated password display (read-only, visible only after Generate)
  CredGeneratedCaption := TNewStaticText.Create(CredentialsPage);
  CredGeneratedCaption.Parent  := CredentialsPage.Surface;
  CredGeneratedCaption.Top     := Y;
  CredGeneratedCaption.Left    := 0;
  CredGeneratedCaption.Caption := 'Generated password (save this now):';
  CredGeneratedCaption.Visible := False;
  Y := Y + CredGeneratedCaption.Height + ScaleY(2);

  // Generated password display (read-only, visible only after Generate)
  CredGeneratedLabel := TNewEdit.Create(CredentialsPage);
  CredGeneratedLabel.Parent   := CredentialsPage.Surface;
  CredGeneratedLabel.Top      := Y;
  CredGeneratedLabel.Left     := 0;
  CredGeneratedLabel.Width    := CredentialsPage.SurfaceWidth;
  CredGeneratedLabel.ReadOnly := True;
  CredGeneratedLabel.Text     := '';
  CredGeneratedLabel.Visible  := False;
end;

procedure InitializeWizard;
begin
  DetectionDone := False;
  ExistingDetectionDone := False;

  // Run existing-install detection synchronously before we create the
  // custom pages. This takes 1-3 seconds (one wsl.exe invocation) and
  // lets us skip the ExistingPage entirely when there's nothing to
  // show. Matches the macOS wizard which scans before showing its
  // Existing-Installation page.
  WizardForm.StatusLabel.Caption := 'Scanning for prior FalconPulsar state...';
  WizardForm.Refresh();
  RunExistingInstallDetection();
  WizardForm.StatusLabel.Caption := '';

  // Create all pages. CreateExistingInstallPage MUST run before
  // CreateLegalPage so the page order ends up:
  //   Welcome -> ExistingInstall (skipped if none) -> Legal -> ...
  CreateExistingInstallPage();
  CreateLegalPage();
  CreateDistroPage();
  CreateRegistryPage();
  CreateCredentialsPage();
end;

// Validate the legal and credentials pages when the user clicks Next.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  // Existing-install page: translate the radio selection to InstallAction.
  // On Fresh, require typing DELETE (matches macOS installer-app UX).
  if (ExistingPage <> nil) and (CurPageID = ExistingPage.ID) then
  begin
    if ExistingFreshRadio.Checked then
    begin
      if ExistingFreshConfirmEdit.Text <> 'DELETE' then
      begin
        MsgBox('To do a Fresh install, type DELETE (uppercase) in the confirmation field.' + #13#10 +
               'This will permanently remove your database and cannot be undone.',
               mbError, MB_OK);
        Result := False;
        Exit;
      end;
      InstallAction := 'fresh';
    end
    else if ExistingReinstallRadio.Checked then
      InstallAction := 'reinstall'
    else
      InstallAction := 'upgrade';
    LogInfo('User chose install action: ' + InstallAction);
  end;

  // Legal page: must have the checkbox ticked
  if (LegalPage <> nil) and (CurPageID = LegalPage.ID) then
  begin
    if not LegalCheckBox.Checked then
    begin
      MsgBox('You must accept the FalconPulsar legal terms to continue.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = CredentialsPage.ID then
  begin
    if Length(CredUserEdit.Text) < 1 then
    begin
      MsgBox('Admin username cannot be empty.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if Length(CredPassEdit.Text) < 10 then
    begin
      MsgBox('Admin password must be at least 10 characters.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if CredPassEdit.Text <> CredConfirmEdit.Text then
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
  Result := CredUserEdit.Text;
end;

function GetAdminPass(Param: String): String;
begin
  Result := CredPassEdit.Text;
end;

function GetLogPath(Param: String): String;
begin
  Result := GetInstallLogPath();
end;

// Top-level prereq check before any page is shown. Anything that's a
// hard-no goes here so the user gets a clear error before they even see
// the welcome screen.
function InitializeSetup(): Boolean;
var
  WinVer: TWindowsVersion;
begin
  Result := True;
  IsUpgrade := False;

  // Initialize the log file -- truncate any previous run
  FpLogFile := GetInstallLogPath();
  SaveStringToFile(FpLogFile,
    '================================================================' + #13#10 +
    '  FalconPulsar Installer Log' + #13#10 +
    '  Version: {#MyAppVersion}' + #13#10 +
    '  Date: ' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + #13#10 +
    '================================================================' + #13#10,
    False);

  LogMachineState();

  // Environment detection is deferred to InitializeWizard (after the
  // window exists) so we can show a "Please wait..." message. Only the
  // instant checks (Windows version, registry key) stay here.

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

  // Existing-install detection is now delegated to the custom wizard page
  // `ExistingPage` (created in InitializeWizard). The page runs the full
  // detection helper (06-detect-existing-install.ps1) which checks BOTH
  // Windows-side state AND WSL-side state (containers, images, volumes,
  // /home/falconpulsar), matching the macOS SwiftUI installer's UX.
  //
  // Default action is 'fresh'; the page overrides it when the user picks
  // Upgrade or Reinstall. IsUpgrade is also set by RunExistingInstallDetection
  // to keep legacy ShouldSkipPage logic working.
  InstallAction := 'fresh';
  IsUpgrade := False;
end;

// Skip the legal and credentials pages on upgrade -- the user already
// accepted the terms and the admin account already exists in the database.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;

  // Skip the Existing-install page when no prior state was detected.
  if (ExistingPage <> nil) and (PageID = ExistingPage.ID) then
  begin
    if not ExistingHasPrior then
      Result := True;
  end;

  // Skip the distro page when 0 or 1 distros detected (nothing to choose)
  if (DistroPage <> nil) and (PageID = DistroPage.ID) then
  begin
    if (DistroCount <= 1) or IsUpgrade then
      Result := True;
  end;

  // Only skip legal + registry when upgrading in place. We still show the
  // credentials page so the user can type the existing admin password —
  // install.sh will verify it against Core before overwriting the stack.
  if IsUpgrade and (InstallAction = 'upgrade') then
  begin
    if (LegalPage <> nil) and (PageID = LegalPage.ID) then
      Result := True;
    if (RegistryPage <> nil) and (PageID = RegistryPage.ID) then
      Result := True;
    // Credentials page intentionally NOT skipped on upgrade — we need the
    // user to enter the existing admin password for auth verification.
  end;
  // Reinstall skips legal (already accepted) but shows registry + credentials
  if IsUpgrade and (InstallAction = 'reinstall') then
  begin
    if (LegalPage <> nil) and (PageID = LegalPage.ID) then
      Result := True;
  end;
end;

// ── Uninstall: ask user what to remove, then run uninstall.ps1 ──────────
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Choice: Integer;
  PurgeFlag: String;
  HelperPath: String;
  FullArgs: String;
  ResultCode: Integer;
  ModeOverride: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    // Kill the tray app if running
    Exec('taskkill.exe', '/F /IM FalconPulsarTray.exe', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode);

    // Honour FP_UNINSTALL_MODE if the caller pre-decided. Set to
    //   'purge' -> remove everything, no MsgBox
    //   'keep'  -> keep data,        no MsgBox
    // Used by `fp uninstall` running inside WSL when it spawns
    // unins000.exe via interop -- the user already answered the prompt
    // on the fp CLI side.
    ModeOverride := GetEnv('FP_UNINSTALL_MODE');
    if ModeOverride = 'purge' then
    begin
      PurgeFlag := '-Purge';
    end
    else if ModeOverride = 'keep' then
    begin
      PurgeFlag := '';
    end
    else
    begin
      // Interactive: ask the user what they want to remove
      Choice := MsgBox(
        'What would you like to remove?' + #13#10 + #13#10 +
        'Click YES to remove everything (containers, data, configuration, ' +
        'database, Start Menu shortcuts). This cannot be undone.' + #13#10 + #13#10 +
        'Click NO to keep your data and database but remove the application ' +
        'files, containers, and shortcuts. You can reinstall later and your ' +
        'data will be preserved.' + #13#10 + #13#10 +
        'Click CANCEL to abort the uninstall.',
        mbConfirmation, MB_YESNOCANCEL);

      if Choice = IDCANCEL then
        Abort;

      if Choice = IDYES then
        PurgeFlag := '-Purge'
      else
        PurgeFlag := '';
    end;

    // Run the PowerShell uninstall helper
    HelperPath := ExpandConstant('{app}\helpers\uninstall.ps1');
    if FileExists(HelperPath) then
    begin
      // -Sta is REQUIRED: uninstall.ps1 calls Assert-AdminAuth which creates
      // a WinForms dialog. PowerShell defaults to MTA since PS 3, and
      // ShowDialog() hangs indefinitely in an MTA apartment. Without -Sta,
      // Inno Setup's progress bar stays stuck on "Uninstalling…" forever
      // because ewWaitUntilTerminated waits on a PS process blocked in a
      // deadlocked WinForms call.
      FullArgs := '-NoProfile -Sta -ExecutionPolicy Bypass -File "' + HelperPath +
        '" -Distro {#WslDistroName}';
      if Length(PurgeFlag) > 0 then
        FullArgs := FullArgs + ' ' + PurgeFlag;

      // SW_SHOWNORMAL (not SW_HIDE): if the WinForms auth dialog never renders,
      // at least the user sees a PowerShell console so they can tell something
      // is happening instead of staring at a frozen progress bar. The actual
      // auth dialog is TopMost anyway.
      Exec('powershell.exe', FullArgs,
        ExpandConstant('{app}\helpers'), SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;
