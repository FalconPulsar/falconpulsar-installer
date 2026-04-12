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

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\helpers\uninstall.ps1"" -Distro {#WslDistroName}"; \
    Flags: runhidden waituntilterminated

[Code]
// =============================================================================
// Pascal Script — custom pages, prereq checks, install orchestrator
// =============================================================================

var
  CredentialsPage: TInputQueryWizardPage;
  LegalPage: TWizardPage;
  LegalCheckBox: TNewCheckBox;
  RegistryPage: TWizardPage;
  RegistryUrlEdit: TNewEdit;
  RegistryUserEdit: TNewEdit;
  RegistryPassEdit: TNewEdit;
  RegistrySkipCheck: TNewCheckBox;
  RegistryTestButton: TNewButton;
  RegistryStatusLabel: TNewStaticText;
  IsUpgrade: Boolean;
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

  // DEBUG: wrap in cmd /c with a pause on failure so the user can read
  // the error before the window closes. Remove this wrapper once the
  // install flow is verified working.
  if not Exec('cmd.exe',
    '/c powershell.exe ' + FullArgs + ' & if errorlevel 1 (echo. & echo === FAILED === Press any key to close... & pause >nul)',
    ExpandConstant('{app}\helpers'), SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
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
begin
  if CurStep = ssPostInstall then
  begin
    FpLogFile := GetInstallLogPath();

    // Truncate the log at the start of the install run. lib.ps1 always
    // appends -- never overwrites -- so this is the single point of init.
    SaveStringToFile(FpLogFile,
      '=== FalconPulsar Windows installer log -- ' +
      GetDateTimeString('yyyy/mm/dd hh:nn:ss', '-', ':') + ' ===' + #13#10,
      False);

    AppDirArg := '-InstallDir "' + ExpandConstant('{app}') + '"';

    // On upgrade, use placeholder credentials -- 40-run-fp-installer.ps1
    // detects the existing data directory and skips the password/init flow.
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
      AdminUserArg := '-AdminUser "' + CredentialsPage.Values[0] + '"';
      AdminPassArg := '-AdminPass "' + CredentialsPage.Values[1] + '"';
      RegistryArg := '-Registry "' + RegistryUrlEdit.Text + '"';
      if Length(RegistryUserEdit.Text) > 0 then
        RegistryUserArg := '-RegistryUser "' + RegistryUserEdit.Text + '"'
      else
        RegistryUserArg := '';
      if Length(RegistryPassEdit.Text) > 0 then
        RegistryPassArg := '-RegistryPass "' + RegistryPassEdit.Text + '"'
      else
        RegistryPassArg := '';
      if RegistrySkipCheck.Checked then
        RegistrySkipArg := '-RegistrySkip'
      else
        RegistrySkipArg := '';
    end;

    if not RunHelper('00-check-prereqs.ps1', '',
        'Checking system prerequisites...') then Abort;

    if not RunHelper('10-enable-wsl.ps1', '',
        'Enabling WSL2 (this may take several minutes on first run)...') then Abort;

    if not RunHelper('20-install-distro.ps1', '-Distro {#WslDistroName}',
        'Installing Ubuntu 24.04 inside WSL (downloading ~500 MB)...') then Abort;

    if not RunHelper('30-configure-distro.ps1', '-Distro {#WslDistroName}',
        'Configuring systemd inside WSL...') then Abort;

    if not RunHelper('40-run-fp-installer.ps1',
        '-Distro {#WslDistroName} ' + AppDirArg + ' ' +
        AdminUserArg + ' ' + AdminPassArg + ' ' +
        RegistryArg + ' ' + RegistryUserArg + ' ' +
        RegistryPassArg + ' ' + RegistrySkipArg,
        'Installing FalconPulsar inside WSL (this may take 5-10 minutes)...') then Abort;

    if not RunHelper('50-register-shortcuts.ps1',
        '-Distro {#WslDistroName} ' + AppDirArg,
        'Registering Start Menu shortcuts...') then Abort;
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
  // "ghcr.io/falconpulsar" -> "ghcr.io"
  // "falconpulsar" (bare Docker Hub namespace) -> "docker.io"
  if Pos('/', UrlVal) > 0 then
    RegHost := Copy(UrlVal, 1, Pos('/', UrlVal) - 1)
  else
    RegHost := 'docker.io';

  // If credentials provided, do a docker login first via a temp file
  // so the password never appears in argv.
  if (Length(UserVal) > 0) and (Length(PassVal) > 0) then
  begin
    PassFile := AddBackslash(GetEnv('TEMP')) + 'fp-reg-pass.tmp';
    SaveStringToFile(PassFile, PassVal, False);
    WslPassFile := WinPathToWsl(PassFile);

    BashCmd := 'cat "' + WslPassFile + '" | docker login "' + RegHost +
      '" --username "' + UserVal + '" --password-stdin >/dev/null 2>&1';
    WslArgs := '-d {#WslDistroName} -u root -- bash -c "' + BashCmd + '"';

    Exec('wsl.exe', WslArgs, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    DeleteFile(PassFile);

    if ResultCode <> 0 then
    begin
      RegistryStatusLabel.Caption := 'FAILED: login rejected by ' + RegHost + '. Check credentials.';
      Exit;
    end;
  end;

  // Probe: docker manifest inspect (HEAD-like, no actual pull)
  BashCmd := 'DOCKER_CLI_HINTS=false docker manifest inspect "' +
    UrlVal + '/core:latest" >/dev/null 2>&1';
  WslArgs := '-d {#WslDistroName} -u root -- bash -c "' + BashCmd + '"';

  if not Exec('wsl.exe', WslArgs, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    RegistryStatusLabel.Caption := 'WSL is not available yet. The install step will handle registry access.';
    Exit;
  end;

  if ResultCode = 0 then
    RegistryStatusLabel.Caption := 'OK: connected and images are pullable.'
  else
    RegistryStatusLabel.Caption := 'FAILED: cannot pull from ' + UrlVal + '. Check URL, credentials, and network.';
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
procedure CreateRegistryPage();
var
  Y: Integer;
  Intro: TNewStaticText;
  UrlLabel: TNewStaticText;
  UserLabel: TNewStaticText;
  PassLabel: TNewStaticText;
begin
  RegistryPage := CreateCustomPage(
    LegalPage.ID,
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

// Custom page: admin username + password (double-entry).
procedure InitializeWizard;
begin
  CreateLegalPage();
  CreateRegistryPage();

  CredentialsPage := CreateInputQueryPage(
    RegistryPage.ID,
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
  IsUpgrade := False;

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
    MsgBox('FalconPulsar is already installed on this computer.' + #13#10 + #13#10 +
           'Click OK to upgrade to the latest version. Your existing data ' +
           'and configuration will be preserved.',
           mbInformation, MB_OK);
  end;
end;

// Skip the legal and credentials pages on upgrade -- the user already
// accepted the terms and the admin account already exists in the database.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
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
