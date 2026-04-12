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
SetupIconFile=assets\falcon.ico
WizardStyle=modern
WizardSizePercent=120
WizardImageFile=assets\welcome.bmp
WizardSmallImageFile=assets\header.bmp
WizardImageStretch=no
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
WelcomeLabel1=Welcome to the FalconPulsar Setup Wizard
WelcomeLabel2=FalconPulsar is an AI-native industrial technology platform.%n%nThis installer will set up the entire FalconPulsar stack on your computer:%n%n  - Core engine (REST API + WebSocket)%n  - Web UI for dashboards, configuration and operations%n  - AI Gateway for natural-language interaction with your data%n%nThe stack runs inside WSL2 (Windows Subsystem for Linux). The installer will set up WSL2 and install Ubuntu 24.04 if they are not already present.%n%nClick Next to continue.

; Finish page — point the user at the Web UI
FinishedLabel=FalconPulsar is now installed and running on your computer.%n%nOpen %1 in any web browser to log in to the Web UI with the admin credentials you set during this install. The admin password is NOT stored on disk anywhere — make sure you saved it.%n%nClick Finish to exit Setup.

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
Source: "..\shared\lib\registry_auth.sh";                   DestDir: "{app}\shared\lib";     Flags: ignoreversion

; ── PowerShell helpers ──────────────────────────────────────────────────────
Source: "helpers\lib.ps1";                                  DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\05-detect-environment.ps1";                 DestDir: "{app}\helpers";        Flags: ignoreversion
; Also include detection files for temp extraction (ExtractTemporaryFile)
; so they can run before {app} is initialized. dontcopy = only extracted
; on demand via Pascal Script, not during normal [Files] processing.
Source: "helpers\05-detect-environment.ps1";                                                     Flags: dontcopy
Source: "helpers\lib.ps1";                                                                       Flags: dontcopy
Source: "helpers\00-check-prereqs.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\10-enable-wsl.ps1";                        DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\20-install-distro.ps1";                    DestDir: "{app}\helpers";        Flags: ignoreversion
Source: "helpers\25-test-registry.ps1";                     DestDir: "{app}\helpers";        Flags: ignoreversion
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
Filename: "notepad.exe"; Parameters: "{code:GetLogPath}"; \
    Description: "View install log"; Flags: postinstall shellexec skipifsilent nowait unchecked

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\helpers\uninstall.ps1"" -Distro {#WslDistroName}"; \
    Flags: runhidden waituntilterminated

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

var
  CredentialsPage: TWizardPage;
  CredUserEdit: TNewEdit;
  CredPassEdit: TNewEdit;
  CredConfirmEdit: TNewEdit;
  CredStrengthLabel: TNewStaticText;
  CredGeneratedLabel: TNewEdit;
  CredGeneratedCaption: TNewStaticText;
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
  FpLogFile: String;
  DetectedWslStatus: String;
  DetectedDockerDesktop: String;
  SelectedDistro: String;
  NeedWslInstall: Boolean;
  NeedDistroInstall: Boolean;

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
  SaveStringToFile(FpLogFile,
    #13#10 + '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') +
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
  // Check radio buttons if the page was shown
  if DistroPage <> nil then
  begin
    for I := 0 to DistroCount - 1 do
    begin
      if DistroRadios[I].Checked then
      begin
        Result := DistroNames[I];
        NeedDistroInstall := False;
        Exit;
      end;
    end;
    // Last radio = "Install fresh Ubuntu 24.04"
    if DistroRadios[DistroCount].Checked then
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
begin
  // Update the wizard status label so the user sees what's happening
  WizardForm.StatusLabel.Caption := StatusMsg;
  WizardForm.Refresh();

  HelperPath := ExpandConstant('{app}\helpers\') + ScriptName;
  FullArgs := '-NoProfile -ExecutionPolicy Bypass -File "' + HelperPath + '"';
  if Length(ExtraArgs) > 0 then
    FullArgs := FullArgs + ' ' + ExtraArgs;

  LogInfo('Running helper: ' + ScriptName);

  if not Exec('cmd.exe',
    '/c powershell.exe ' + FullArgs + ' & if errorlevel 1 (echo. & echo === FAILED === Press any key to close... & pause >nul)',
    ExpandConstant('{app}\helpers'), SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
  begin
    LogError('Helper ' + ScriptName + ' failed to launch');
    ShowStepError(StatusMsg, -1);
    Result := False;
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    LogError('Helper ' + ScriptName + ' exited with code ' + IntToStr(ResultCode));
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
  Distro: String;
  DistroArg: String;
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

    if IsUpgrade then
    begin
      AdminUserArg := '-AdminUser "admin"';
      AdminPassArg := '-AdminPass "upgrade-placeholder"';
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
    if DetectedDockerDesktop = 'installed' then
    begin
      if MsgBox(
        'Docker Desktop is installed on this machine but is not currently ' +
        'running.' + #13#10 + #13#10 +
        'If you use Docker Desktop as your container engine, please start ' +
        'it now and click OK to continue.' + #13#10 + #13#10 +
        'If you want the installer to set up its own Docker Engine inside ' +
        'WSL instead (independent of Docker Desktop), click OK without ' +
        'starting Docker Desktop.',
        mbInformation, MB_OKCANCEL) = IDCANCEL then
        Abort;
    end;

    // Always run prereq checks
    LogStep('Step 1/6: System prerequisites');
    if not RunHelper('00-check-prereqs.ps1', '',
        'Checking system prerequisites...') then Abort;
    LogInfo('Step 1/6: PASSED');

    // Only enable WSL if not already working
    if NeedWslInstall then
    begin
      LogStep('Step 2/6: Enabling WSL2');
      if not RunHelper('10-enable-wsl.ps1', '',
          'Enabling WSL2 (this may take several minutes on first run)...') then Abort;
      LogInfo('Step 2/6: PASSED');
    end else
      LogInfo('Step 2/6: SKIPPED (WSL already working)');

    // Only install a distro if user chose "Install fresh" or none exists
    if NeedDistroInstall then
    begin
      LogStep('Step 3/6: Installing ' + Distro);
      if not RunHelper('20-install-distro.ps1', DistroArg,
          'Installing ' + Distro + ' inside WSL...') then Abort;
      LogInfo('Step 3/6: PASSED');
    end else
      LogInfo('Step 3/6: SKIPPED (using existing distro ' + Distro + ')');

    // Always configure systemd (idempotent)
    LogStep('Step 4/6: Configuring systemd');
    if not RunHelper('30-configure-distro.ps1', DistroArg,
        'Configuring systemd inside ' + Distro + '...') then Abort;
    LogInfo('Step 4/6: PASSED');

    // Run the bash installer inside the selected distro
    LogStep('Step 5/6: FalconPulsar bash installer');
    if not RunHelper('40-run-fp-installer.ps1',
        DistroArg + ' ' + AppDirArg + ' ' +
        AdminUserArg + ' ' + AdminPassArg + ' ' +
        RegistryArg + ' ' + RegistryUserArg + ' ' +
        RegistryPassArg + ' ' + RegistrySkipArg,
        'Installing FalconPulsar inside WSL (this may take 5-10 minutes)...') then Abort;
    LogInfo('Step 5/6: PASSED');

    // Register shortcuts with the correct distro name
    LogStep('Step 6/6: Start Menu shortcuts');
    if not RunHelper('50-register-shortcuts.ps1',
        DistroArg + ' ' + AppDirArg,
        'Registering Start Menu shortcuts...') then Abort;
    LogInfo('Step 6/6: PASSED');

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
begin
  if (LegalPage <> nil) and (CurPageID = LegalPage.ID) then
    WizardForm.NextButton.Enabled := LegalCheckBox.Checked;
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
begin
  Strength := GetPasswordStrength(CredPassEdit.Text);
  if Length(CredPassEdit.Text) = 0 then
    CredStrengthLabel.Caption := ''
  else
    CredStrengthLabel.Caption := 'Password strength: ' + Strength;
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
  CopyButton: TNewButton;
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
  CredPassEdit.Width        := CredentialsPage.SurfaceWidth;
  CredPassEdit.PasswordChar := '*';
  CredPassEdit.OnChange     := @CredPassChange;
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

  // Strength indicator
  CredStrengthLabel := TNewStaticText.Create(CredentialsPage);
  CredStrengthLabel.Parent   := CredentialsPage.Surface;
  CredStrengthLabel.Top      := Y;
  CredStrengthLabel.Left     := 0;
  CredStrengthLabel.Width    := CredentialsPage.SurfaceWidth;
  CredStrengthLabel.AutoSize := False;
  CredStrengthLabel.Height   := ScaleY(16);
  CredStrengthLabel.Caption  := '';
  Y := Y + CredStrengthLabel.Height + ScaleY(4);

  // Requirements text
  ReqLabel := TNewStaticText.Create(CredentialsPage);
  ReqLabel.Parent   := CredentialsPage.Surface;
  ReqLabel.Top      := Y;
  ReqLabel.Left     := 0;
  ReqLabel.Width    := CredentialsPage.SurfaceWidth;
  ReqLabel.AutoSize := False;
  ReqLabel.Height   := ScaleY(16);
  ReqLabel.Caption  := 'Min 10 chars. Use uppercase, lowercase, numbers, and symbols for a strong password.';
  ReqLabel.Font.Color := clGray;
  Y := Y + ReqLabel.Height + ScaleY(12);

  // Generate + Copy buttons side by side
  GenButton := TNewButton.Create(CredentialsPage);
  GenButton.Parent  := CredentialsPage.Surface;
  GenButton.Top     := Y;
  GenButton.Left    := 0;
  GenButton.Width   := ScaleX(160);
  GenButton.Height  := ScaleY(25);
  GenButton.Caption := 'Generate strong password';
  GenButton.OnClick := @CredGenerateClick;

  CopyButton := TNewButton.Create(CredentialsPage);
  CopyButton.Parent  := CredentialsPage.Surface;
  CopyButton.Top     := Y;
  CopyButton.Left    := ScaleX(170);
  CopyButton.Width   := ScaleX(120);
  CopyButton.Height  := ScaleY(25);
  CopyButton.Caption := 'Copy password';
  CopyButton.OnClick := @CredCopyClick;
  Y := Y + GenButton.Height + ScaleY(8);

  // Generated password display (read-only, visible only after Generate)
  CredGeneratedCaption := TNewStaticText.Create(CredentialsPage);
  CredGeneratedCaption.Parent  := CredentialsPage.Surface;
  CredGeneratedCaption.Top     := Y;
  CredGeneratedCaption.Left    := 0;
  CredGeneratedCaption.Caption := 'Generated password (save this now):';
  CredGeneratedCaption.Visible := False;
  Y := Y + CredGeneratedCaption.Height + ScaleY(2);

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
  CreateLegalPage();
  CreateDistroPage();
  CreateRegistryPage();
  CreateCredentialsPage();

  // Bring the wizard to the foreground after UAC elevation. Windows
  // suppresses focus theft from new processes by default, so the elevated
  // setup.exe lands in the taskbar instead of on top of the user's desktop.
  // Calling BringToFront() from InitializeWizard runs after the form is
  // realized and shoves it back to the foreground.
  WizardForm.BringToFront();
end;

// Validate the legal and credentials pages when the user clicks Next.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

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

  // Log machine state first
  LogMachineState();

  // Run environment detection before any page is shown.
  LogStep('Running environment detection');
  RunDetection();
  LogDetectionResults();

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

  // Detect existing installation via the Inno Setup uninstall registry key.
  // This key only exists after a COMPLETED previous install -- partial or
  // failed installs (e.g. test runs that left files behind) don't have it.
  // The AppId from [Setup] with '_is1' suffix is the standard Inno key name.
  if RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{#SetupSetting("AppId")}_is1') or
     RegKeyExists(HKCU, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{#SetupSetting("AppId")}_is1') then
  begin
    IsUpgrade := True;
    LogInfo('Existing installation detected -- upgrade mode');
    MsgBox('FalconPulsar is already installed on this computer.' + #13#10 + #13#10 +
           'Click OK to upgrade to the latest version. Your existing data ' +
           'and configuration will be preserved.',
           mbInformation, MB_OK);
  end else
    LogInfo('No existing installation found -- fresh install mode');
end;

// Skip the legal and credentials pages on upgrade -- the user already
// accepted the terms and the admin account already exists in the database.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;

  // Skip the distro page when 0 or 1 distros detected (nothing to choose)
  if (DistroPage <> nil) and (PageID = DistroPage.ID) then
  begin
    if (DistroCount <= 1) or IsUpgrade then
      Result := True;
  end;

  if IsUpgrade then
  begin
    if (LegalPage <> nil) and (PageID = LegalPage.ID) then
      Result := True;
    if (RegistryPage <> nil) and (PageID = RegistryPage.ID) then
      Result := True;
    if (CredentialsPage <> nil) and (PageID = CredentialsPage.ID) then
      Result := True;
  end;
end;
