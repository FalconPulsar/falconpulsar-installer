// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FalconPulsar.Tray
{
    public enum StackStatus
    {
        Unknown,
        Running,
        PartiallyRunning,
        Stopped,
        Error
    }

    public class TrayApp : IDisposable
    {
        private readonly NotifyIcon _trayIcon;
        private readonly System.Windows.Forms.Timer _pollTimer;
        private readonly HttpClient _http;
        private readonly string _distro;
        private readonly string _composePath;

        private StackStatus _status = StackStatus.Unknown;
        private bool _dockerDaemonUp;
        private bool _coreRunning;
        private bool _uiRunning;
        private bool _gatewayRunning;
        private bool _apiHealthy;
        private bool _engineEnabled;
        private bool _engineRunning;
        private bool _copilotEnabled;
        private bool _copilotRunning;

        private ToolStripMenuItem _coreItem;
        private ToolStripMenuItem _uiItem;
        private ToolStripMenuItem _gatewayItem;
        private ToolStripMenuItem _apiItem;
        private ToolStripMenuItem _engineItem;
        private ToolStripMenuItem _openEngineItem;
        private ToolStripMenuItem _copilotItem;
        private ToolStripMenuItem _openCopilotItem;
        private ToolStripMenuItem _startItem;
        private ToolStripMenuItem _stopItem;
        private ToolStripMenuItem _restartItem;
        private ToolStripMenuItem _autoStartItem;
        private ToolStripMenuItem _autoUpdateCheckItem;
        private ToolStripMenuItem _updateAvailableItem;

        // ── Automatic update checking (FP_UPDATE_CHECK_AUTO) ──
        // Armed only while the flag is ON; see EnsureAutoUpdateTimers.
        // Checking is read-only — applying updates is always an explicit
        // user action. Mirrors the macOS menu bar app.
        private System.Windows.Forms.Timer _updateInitialTimer;  // one-shot, ~2 min after launch
        private System.Windows.Forms.Timer _updateDailyTimer;    // hourly gate, ≤1 check/24h
        private DateTime _lastAutoUpdateCheck = DateTime.MinValue;
        private bool _updateCheckAutoEnabled;
        private bool _autoUpdateCheckRunning;
        // Passive indicator state (tray tooltip suffix + hidden menu row).
        private bool _updateAvailable;
        private string _updateAvailableVersion = "";

        // WSL stack location, resolved once at tray startup. The installer
        // writes `falconpulsar-home.txt` next to the distro sentinel; if
        // that's missing we probe the distro's default user (`whoami`) and
        // compute /home/<user>/falconpulsar. As a last resort we fall back
        // to the legacy /home/falconpulsar path so a legacy install still
        // works until the user reinstalls.
        private readonly string _wslHome;
        private readonly string _wslHomeUnc;

        public TrayApp()
        {
            _distro = ReadDistroName();
            _wslHome = ReadWslHome(_distro);
            // Convert /home/<user>/falconpulsar to \\wsl.localhost\<distro>\home\<user>\falconpulsar
            _wslHomeUnc = $@"\\wsl.localhost\{_distro}" + _wslHome.Replace('/', '\\');
            _composePath = _wslHome + "/compose.yml";

            // Config Backup must export/import the real stack files inside
            // WSL — the same directory the Config Files menu opens — not the
            // legacy %USERPROFILE%\falconpulsar mirror.
            ConfigBackup.FalconPulsarHomeDir = _wslHomeUnc;

            _http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };

            _trayIcon = new NotifyIcon
            {
                Text = "FalconPulsar",
                Icon = CreateStatusIcon(Color.Gray),
                Visible = true,
                ContextMenuStrip = BuildMenu()
            };
            _trayIcon.DoubleClick += (s, e) => OpenWebUI();

            _pollTimer = new System.Windows.Forms.Timer { Interval = 15000 };
            _pollTimer.Tick += async (s, e) => await PollHealth();
            _pollTimer.Start();

            // Arm the automatic update-check timers when the .env flag is
            // already ON at launch. OFF (the default) arms nothing — zero
            // background update traffic.
            _updateCheckAutoEnabled = UpdateCheckAutoEnabled;
            EnsureAutoUpdateTimers();

            _ = PollHealth();
        }

        // WSL distro names are documented as alphanumerics + dot/underscore/hyphen.
        // We interpolate _distro into `wsl.exe -d {_distro} ...` arguments and into
        // a UNC path, so any character outside this set is a defense-in-depth red
        // flag — even though the source files (Program Files config, %TEMP%
        // sentinel) are only writable by privileged installs / the same user.
        private static readonly System.Text.RegularExpressions.Regex _distroNameRe =
            new(@"^[A-Za-z0-9_.-]+$");

        private string ReadDistroName()
        {
            // Try config file first (written by installer)
            var configPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "FalconPulsar", "tray-config.txt");
            if (File.Exists(configPath))
            {
                var distro = File.ReadAllText(configPath).Trim();
                if (IsValidDistroName(distro)) return distro;
            }

            // Try sentinel file
            var sentinel = Path.Combine(Path.GetTempPath(), "falconpulsar-distro.txt");
            if (File.Exists(sentinel))
            {
                var distro = File.ReadAllText(sentinel).Trim();
                if (IsValidDistroName(distro)) return distro;
            }

            return "Ubuntu-24.04";
        }

        // Reject anything that could break out of `wsl.exe -d <name>` argument
        // parsing (spaces, quotes, semicolons, ampersands, etc.). The fallback
        // "Ubuntu-24.04" is used when validation fails so the tray still works.
        private static bool IsValidDistroName(string distro) =>
            !string.IsNullOrEmpty(distro) && _distroNameRe.IsMatch(distro);

        private static string ReadWslHome(string distro)
        {
            // 1. Sentinel written by the installer at %TEMP%\falconpulsar-home.txt.
            var sentinel = Path.Combine(Path.GetTempPath(), "falconpulsar-home.txt");
            if (File.Exists(sentinel))
            {
                var home = File.ReadAllText(sentinel).Trim();
                if (!string.IsNullOrEmpty(home) && home.StartsWith("/"))
                    return home;
            }

            // 2. Ask the distro for the default user's $HOME.
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {distro} -- sh -c \"printf %s \\\"$HOME\\\"\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true
                };
                using var proc = Process.Start(psi);
                if (proc != null)
                {
                    var stdout = proc.StandardOutput.ReadToEnd();
                    proc.WaitForExit(3000);
                    var home = stdout.Replace("\0", "").Trim().TrimStart('\uFEFF');
                    if (!string.IsNullOrEmpty(home) && home.StartsWith("/"))
                        return home + "/falconpulsar";
                }
            }
            catch { }

            // 3. Legacy service-user path as a last resort.
            return "/home/falconpulsar";
        }

        // Reads one value out of the stack's .env inside WSL, via the same
        // resolved \\wsl.localhost UNC path the Config Files menu uses.
        // Returns null when the file or key is missing. Last occurrence
        // wins, matching docker compose's own env-file semantics, so a
        // hand-appended override behaves the same here and in the stack
        // itself (mirrors AppDelegate.envValue on macOS).
        private string EnvValue(string key)
        {
            try
            {
                var envPath = Path.Combine(_wslHomeUnc, ".env");
                if (!File.Exists(envPath)) return null;
                string value = null;
                foreach (var line in File.ReadAllLines(envPath))
                {
                    var trimmed = line.Trim();
                    if (!trimmed.StartsWith(key + "=")) continue;
                    var v = trimmed.Substring(key.Length + 1).Trim();
                    if (v.Length > 0) value = v;
                }
                return value;
            }
            catch
            {
                // UNC reads can fail while WSL is starting/stopping —
                // fall back to the installer defaults below.
                return null;
            }
        }

        // Ports come from the stack's .env so port-remapped installs report
        // health and open the Web UI correctly; the literals are only the
        // installer defaults, used when .env is missing or doesn't set them.
        private string RestPort => EnvValue("FP_REST_PORT") ?? "7433";
        private string UiPort => EnvValue("FP_UI_PORT") ?? "8080";
        private string EnginePort => EnvValue("FP_ENGINE_PORT") ?? "8085";
        private string CopilotPort => EnvValue("FP_COPILOT_PORT") ?? "8090";

        // Optional AI Engine service (compose profile "engine"). The
        // installer writes FP_AI_ENGINE_ENABLED=true into .env when the
        // user opts in; absent/false on most installs. Trim + case-
        // insensitive so a hand-edited "True" still counts.
        private bool EngineEnabled =>
            string.Equals(EnvValue("FP_AI_ENGINE_ENABLED")?.Trim(), "true",
                StringComparison.OrdinalIgnoreCase);

        // Optional Command Center service (compose profile "copilot"). The
        // installer writes FP_COPILOT_ENABLED=true when the user opts in.
        private bool CopilotEnabled =>
            string.Equals(EnvValue("FP_COPILOT_ENABLED")?.Trim(), "true",
                StringComparison.OrdinalIgnoreCase);

        // Automatic update *checking* opt-in: FP_UPDATE_CHECK_AUTO=true in
        // the stack .env means "check in the background"; absent or any
        // other value = OFF (the default). Checking never applies anything.
        // Trim + case-insensitive matches the EngineEnabled convention so
        // a hand-edited "True" still counts (mirrors macOS).
        private bool UpdateCheckAutoEnabled =>
            string.Equals(EnvValue("FP_UPDATE_CHECK_AUTO")?.Trim(), "true",
                StringComparison.OrdinalIgnoreCase);

        // Our own version, read from the assembly. Set at build time by
        // <Version> in FalconPulsarTray.csproj, and overridable from CI
        // via `dotnet publish -p:Version=$VER`. Falls back to "dev" on
        // unbundled debug builds where AssemblyVersion is not set.
        private static string AssemblyVersion =>
            System.Reflection.Assembly
                .GetExecutingAssembly()
                .GetName()
                .Version?.ToString(3) ?? "dev";

        // Full product version used for the tray's own row in the update
        // dialog's host section. Application.ProductVersion surfaces
        // AssemblyInformationalVersion — the MSBuild <Version> property,
        // which CI injects via -p:Version (build-windows.yml/release.yml).
        // Two caveats NormalizeVersion/HostVersionsEquivalent handle:
        //   • the .NET 8 SDK appends "+<git-sha>" build metadata when
        //     building inside a git checkout (CI does) — stripped;
        //   • CI strips -alpha/-beta/-rc suffixes (System.Version can't
        //     represent them), so a release tray only knows "0.1.4" while
        //     the latest-release feed says "0.1.4-alpha.28" — see
        //     HostVersionsEquivalent for the numeric-core fallback.
        private static string TrayProductVersion =>
            NormalizeVersion(Application.ProductVersion);

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();

            // Header — full semver (matches the macOS menu-bar header). Use
            // TrayProductVersion, not AssemblyVersion: the latter is the numeric
            // System.Version (0.1.4) which cannot carry the -alpha.NN suffix, so
            // it rendered as "FalconPulsar v0.1.4" with the pre-release dropped.
            var header = new ToolStripMenuItem($"FalconPulsar v{TrayProductVersion}")
            { Enabled = false };
            header.Font = new Font(header.Font, FontStyle.Bold);
            menu.Items.Add(header);
            menu.Items.Add(new ToolStripSeparator());

            // Status items
            _coreItem = new ToolStripMenuItem("Core: checking...");
            _uiItem = new ToolStripMenuItem("Web UI: checking...");
            _gatewayItem = new ToolStripMenuItem("AI Capabilities: checking...");
            _apiItem = new ToolStripMenuItem("REST API: checking...");
            // Optional AI Engine row — hidden unless FP_AI_ENGINE_ENABLED=true
            // in .env; visibility is re-evaluated on every poll in UpdateUI.
            _engineItem = new ToolStripMenuItem("AI Engine: checking...")
            { Visible = false };
            // Optional Command Center row — hidden unless FP_COPILOT_ENABLED=true
            // in .env; visibility is re-evaluated on every poll in UpdateUI.
            _copilotItem = new ToolStripMenuItem("Command Center: checking...")
            { Visible = false };
            menu.Items.Add(_coreItem);
            menu.Items.Add(_uiItem);
            menu.Items.Add(_gatewayItem);
            menu.Items.Add(_apiItem);
            menu.Items.Add(_engineItem);
            menu.Items.Add(_copilotItem);
            menu.Items.Add(new ToolStripSeparator());

            // Actions
            var openUi = new ToolStripMenuItem("Open FalconPulsar", null,
                (s, e) => OpenWebUI());
            openUi.Font = new Font(openUi.Font, FontStyle.Bold);
            openUi.Image = CreateGlyphIcon("\uE774", Color.FromArgb(70, 70, 70));  // Globe
            menu.Items.Add(openUi);

            // Optional AI Engine UI — hidden unless FP_AI_ENGINE_ENABLED=true
            // in .env; visibility is re-evaluated on every poll in UpdateUI.
            _openEngineItem = new ToolStripMenuItem("Open AI Engine", null,
                (s, e) => OpenAiEngine());
            _openEngineItem.Image = CreateGlyphIcon("\uE99A", Color.FromArgb(70, 70, 70));  // Robot
            _openEngineItem.Visible = false;
            menu.Items.Add(_openEngineItem);

            // Optional Command Center UI \u2014 hidden unless FP_COPILOT_ENABLED=true
            // in .env; visibility is re-evaluated on every poll in UpdateUI.
            _openCopilotItem = new ToolStripMenuItem("Open Command Center", null,
                (s, e) => OpenCopilot());
            _openCopilotItem.Image = CreateGlyphIcon("\uE80F", Color.FromArgb(70, 70, 70));  // Home
            _openCopilotItem.Visible = false;
            menu.Items.Add(_openCopilotItem);

            _startItem = new ToolStripMenuItem("Start Stack", null,
                async (s, e) => await RunComposeCommand("up -d"));
            _startItem.Image = CreateGlyphIcon("\uE768", Color.FromArgb(70, 70, 70));  // Play
            _stopItem = new ToolStripMenuItem("Stop Stack", null,
                async (s, e) => await RunComposeCommand("down"));
            _stopItem.Image = CreateSquareIcon(Color.FromArgb(70, 70, 70));  // Stop (drawn square)
            _restartItem = new ToolStripMenuItem("Restart Stack", null,
                async (s, e) => await RunComposeCommand("restart"));
            _restartItem.Image = CreateGlyphIcon("\uE72C", Color.FromArgb(70, 70, 70));  // Refresh
            menu.Items.Add(_startItem);
            menu.Items.Add(_stopItem);
            menu.Items.Add(_restartItem);

            // "Check for updates..." \u2014 between the stack-control items and
            // the Tools/logs section, matching the macOS menu order. Shells
            // out to `fp update --json` (check is the default mode; the
            // binary lives in the WSL distro's $HOME/falconpulsar/bin);
            // apply path opens a Windows Terminal window running `fp update
            // --apply` so the operator can watch progress.
            var checkUpdates = new ToolStripMenuItem("Check for Updates...", null,
                async (s, e) => await CheckForUpdatesAsync());
            checkUpdates.Image = CreateGlyphIcon("\uE896", Color.FromArgb(70, 70, 70));  // Download
            menu.Items.Add(checkUpdates);

            // Passive indicator row \u2014 hidden until an automatic background
            // check finds something ("Update available: vX"); clicking it
            // runs the normal Check-for-Updates flow above. It never
            // applies anything by itself (no popups, no downloads).
            _updateAvailableItem = new ToolStripMenuItem("Update available", null,
                async (s, e) => await CheckForUpdatesAsync());
            _updateAvailableItem.Image = CreateGlyphIcon("\uE74A", Color.FromArgb(243, 140, 25));  // Up arrow, warm orange
            _updateAvailableItem.Visible = false;
            menu.Items.Add(_updateAvailableItem);

            // Toggles FP_UPDATE_CHECK_AUTO in the stack .env (replace an
            // existing line in place or append one; other lines untouched).
            // ON: check at most once per 24h plus once ~2 minutes after
            // launch, surfacing results only through the passive indicator
            // above. OFF (default): no timers run \u2014 zero background update
            // traffic. Mirrors the macOS menu bar app.
            _autoUpdateCheckItem = new ToolStripMenuItem("Automatically check for updates", null,
                async (s, e) => await ToggleUpdateCheckAutoAsync());
            _autoUpdateCheckItem.Checked = UpdateCheckAutoEnabled;
            menu.Items.Add(_autoUpdateCheckItem);
            menu.Items.Add(new ToolStripSeparator());

            // Tools
            menu.Items.Add(new ToolStripMenuItem("View Logs", null,
                (s, e) => ViewLogs()));
            menu.Items.Add(new ToolStripMenuItem("Open Data Folder", null,
                (s, e) => OpenDataFolder()));
            menu.Items.Add(new ToolStripMenuItem("Open Install Log", null,
                (s, e) => OpenInstallLog()));

            // Config Files submenu
            var configMenu = new ToolStripMenuItem("Config Files");
            configMenu.DropDownItems.Add(new ToolStripMenuItem("Core (falconpulsar.toml)", null,
                (s, e) => EditConfigFile("data/falconpulsar.toml")));
            configMenu.DropDownItems.Add(new ToolStripMenuItem("AI Capabilities (gateway.yaml)", null,
                (s, e) => EditConfigFile("gateway.yaml")));
            configMenu.DropDownItems.Add(new ToolStripMenuItem("Docker Compose (compose.yml)", null,
                (s, e) => EditConfigFile("compose.yml")));
            configMenu.DropDownItems.Add(new ToolStripSeparator());
            configMenu.DropDownItems.Add(new ToolStripMenuItem("Open Config Folder", null,
                (s, e) => OpenDataFolder()));
            menu.Items.Add(configMenu);

            // Order below matches the macOS menu bar exactly so users on
            // both platforms find items in the same place:
            //   Config Files → Configuration Backup

            // Configuration Backup submenu (export / import)
            var backupMenu = new ToolStripMenuItem("Configuration Backup");
            backupMenu.DropDownItems.Add(new ToolStripMenuItem("Export Configuration...", null,
                async (s, e) => await ExportConfigurationAsync()));
            backupMenu.DropDownItems.Add(new ToolStripMenuItem("Import Configuration...", null,
                async (s, e) => await ImportConfigurationAsync()));
            menu.Items.Add(backupMenu);

            menu.Items.Add(new ToolStripSeparator());

            // Settings
            _autoStartItem = new ToolStripMenuItem("Start with Windows", null,
                (s, e) => ToggleAutoStart());
            _autoStartItem.Checked = IsAutoStartEnabled();
            menu.Items.Add(_autoStartItem);

            menu.Items.Add(new ToolStripMenuItem("Documentation", null,
                (s, e) => Process.Start(new ProcessStartInfo("https://falconpulsar.com/docs")
                { UseShellExecute = true })));

            var requestFeature = new ToolStripMenuItem("Request a Feature...", null,
                (s, e) => Process.Start(new ProcessStartInfo("https://falconpulsar.com/roadmap#request-form")
                { UseShellExecute = true }));
            requestFeature.Image = CreateGlyphIcon("\uEA80", Color.FromArgb(243, 140, 25));  // Lightbulb, warm orange
            menu.Items.Add(requestFeature);

            menu.Items.Add(new ToolStripMenuItem("Refresh Status", null,
                async (s, e) => await PollHealth()));
            menu.Items.Add(new ToolStripMenuItem("About FalconPulsar", null,
                (s, e) => ShowAbout()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Uninstall FalconPulsar...", null,
                (s, e) => UninstallFalconPulsar()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Exit", null,
                (s, e) => ExitApp()));

            return menu;
        }

        private async Task PollHealth()
        {
            // First check: is the Docker daemon itself reachable? If not,
            // every container query below returns false and we used to
            // report "Stopped" — misleading because the user might think
            // FalconPulsar has a problem when Docker Desktop is just off.
            _dockerDaemonUp = await IsDockerDaemonRunning();

            // Re-read the AI Engine opt-in each poll (cheap .env read) so
            // enabling/disabling it takes effect without restarting the tray.
            _engineEnabled = EngineEnabled;
            _copilotEnabled = CopilotEnabled;

            // Same for the auto update-check flag: a hand-edit of .env
            // arms/disarms the timers without restarting the tray.
            _updateCheckAutoEnabled = UpdateCheckAutoEnabled;
            EnsureAutoUpdateTimers();

            if (_dockerDaemonUp)
            {
                _coreRunning = await IsContainerRunning("falconpulsar-core");
                _uiRunning = await IsContainerRunning("falconpulsar-ui");
                _gatewayRunning = await IsContainerRunning("falconpulsar-ai-gateway");
                _engineRunning = _engineEnabled && await IsContainerRunning("falconpulsar-ai-engine");
                _copilotRunning = _copilotEnabled && await IsContainerRunning("falconpulsar-copilot");
                _apiHealthy = await IsApiHealthy();
            }
            else
            {
                _coreRunning = false;
                _uiRunning = false;
                _gatewayRunning = false;
                _engineRunning = false;
                _copilotRunning = false;
                _apiHealthy = false;
            }

            // Determine overall status
            var prev = _status;
            if (!_dockerDaemonUp)
            {
                _status = StackStatus.Error;   // Docker Desktop / WSL docker is down
            }
            else
            {
                // The AI Engine only participates in the aggregate when the
                // install opted in — a disabled engine must not drag an
                // otherwise-healthy stack down to "partially running".
                var allExpected = _coreRunning && _uiRunning && _gatewayRunning
                    && (!_engineEnabled || _engineRunning)
                    && (!_copilotEnabled || _copilotRunning);
                var anyRunning = _coreRunning || _uiRunning || _gatewayRunning
                    || _engineRunning || _copilotRunning;
                if (allExpected && _apiHealthy)
                    _status = StackStatus.Running;
                else if (anyRunning)
                    _status = StackStatus.PartiallyRunning;
                else
                    _status = StackStatus.Stopped;
            }

            UpdateUI();

            // Notification on status change
            if (prev != StackStatus.Unknown && prev != _status)
            {
                if (_status == StackStatus.Running)
                    ShowNotification("FalconPulsar is running", "All containers are healthy.",
                        ToolTipIcon.Info);
                else if (_status == StackStatus.Stopped)
                    ShowNotification("FalconPulsar stopped", "All containers have stopped.",
                        ToolTipIcon.Warning);
                else if (_status == StackStatus.PartiallyRunning)
                    ShowNotification("FalconPulsar partially running",
                        "Some containers are not running.", ToolTipIcon.Warning);
            }
        }

        private void UpdateUI()
        {
            // Update icon color
            Color color;
            string tooltip;
            switch (_status)
            {
                case StackStatus.Running:
                    color = Color.FromArgb(34, 197, 94); // green
                    tooltip = "FalconPulsar: Running";
                    break;
                case StackStatus.PartiallyRunning:
                    color = Color.FromArgb(234, 179, 8); // yellow
                    tooltip = "FalconPulsar: Partially running";
                    break;
                case StackStatus.Stopped:
                    color = Color.FromArgb(239, 68, 68); // red
                    tooltip = "FalconPulsar: Stopped";
                    break;
                case StackStatus.Error:
                    color = Color.FromArgb(239, 68, 68); // red
                    tooltip = "FalconPulsar: Docker Desktop is not running";
                    break;
                default:
                    color = Color.Gray;
                    tooltip = "FalconPulsar: Checking...";
                    break;
            }
            // Passive update indicator: tooltip suffix + hidden menu row.
            // Set only by an update check (automatic or manual) — never a
            // popup. Suffix kept short: NotifyIcon.Text has a hard length
            // cap and the longest base tooltip is already 44 chars.
            if (_updateAvailable)
                tooltip += " (update available)";

            _trayIcon.Icon = CreateStatusIcon(color, _updateAvailable);
            _trayIcon.Text = tooltip;

            _updateAvailableItem.Visible = _updateAvailable;
            if (_updateAvailable)
                _updateAvailableItem.Text = string.IsNullOrEmpty(_updateAvailableVersion)
                    ? "Update available"
                    : $"Update available: v{_updateAvailableVersion}";

            // Keep the toggle's check state in sync with .env (it can be
            // hand-edited outside the tray).
            _autoUpdateCheckItem.Checked = _updateCheckAutoEnabled;

            // AI Engine row + "Open AI Engine" only show on engine-enabled
            // installs; re-toggled every pass so .env edits apply without
            // restarting the tray.
            _engineItem.Visible = _engineEnabled;
            _openEngineItem.Visible = _engineEnabled;
            _copilotItem.Visible = _copilotEnabled;
            _openCopilotItem.Visible = _copilotEnabled;

            // Update menu items. When Docker daemon is down, show a single
            // "Docker Desktop not running" item instead of N red dots —
            // more useful to the user than four separate "stopped" rows.
            if (!_dockerDaemonUp)
            {
                _coreItem.Text = "Docker Desktop is not running";
                _coreItem.Image = CreateDot(Color.Red);
                _uiItem.Text = "Start Docker Desktop, then click Refresh Status";
                _uiItem.Image = CreateDot(Color.Gray);
                _gatewayItem.Text = "";
                _gatewayItem.Image = null;
                _apiItem.Text = "";
                _apiItem.Image = null;
                _engineItem.Text = "";
                _engineItem.Image = null;
                _copilotItem.Text = "";
                _copilotItem.Image = null;
            }
            else
            {
                _coreItem.Text = _coreRunning ? "Core: Running" : "Core: Stopped";
                _coreItem.Image = CreateDot(_coreRunning ? Color.Green : Color.Red);
                _uiItem.Text = _uiRunning ? "Web UI: Running" : "Web UI: Stopped";
                _uiItem.Image = CreateDot(_uiRunning ? Color.Green : Color.Red);
                _gatewayItem.Text = _gatewayRunning ? "AI Capabilities: Running" : "AI Capabilities: Stopped";
                _gatewayItem.Image = CreateDot(_gatewayRunning ? Color.Green : Color.Red);
                _apiItem.Text = _apiHealthy ? "REST API: Healthy" : "REST API: Not responding";
                _apiItem.Image = CreateDot(_apiHealthy ? Color.Green : Color.Gray);
                _engineItem.Text = _engineRunning ? "AI Engine: Running" : "AI Engine: Stopped";
                _engineItem.Image = CreateDot(_engineRunning ? Color.Green : Color.Red);
                _copilotItem.Text = _copilotRunning ? "Command Center: Running" : "Command Center: Stopped";
                _copilotItem.Image = CreateDot(_copilotRunning ? Color.Green : Color.Red);
            }

            // Enable/disable actions based on state
            _startItem.Enabled = _status != StackStatus.Running;
            _stopItem.Enabled = _status != StackStatus.Stopped;
            _restartItem.Enabled = _status != StackStatus.Stopped;
        }

        // Probe the Docker daemon (via WSL) before asking about individual
        // containers. Returns false when Docker Desktop is off, when WSL
        // integration is disabled for the distro, or when dockerd itself
        // is shutting down. Used by PollHealth to distinguish "stack is
        // stopped" from "Docker is not running at all".
        private async Task<bool> IsDockerDaemonRunning()
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {_distro} -u root -- docker info --format '{{{{.ServerVersion}}}}'",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                var output = await proc.StandardOutput.ReadToEndAsync();
                await proc.WaitForExitAsync();
                return proc.ExitCode == 0 && !string.IsNullOrWhiteSpace(output);
            }
            catch
            {
                return false;
            }
        }

        private async Task<bool> IsContainerRunning(string name)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {_distro} -u root -- docker ps --filter name={name} --filter status=running -q",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                var output = await proc.StandardOutput.ReadToEndAsync();
                await proc.WaitForExitAsync();
                return !string.IsNullOrWhiteSpace(output);
            }
            catch
            {
                return false;
            }
        }

        private async Task<bool> IsApiHealthy()
        {
            try
            {
                var resp = await _http.GetAsync($"http://localhost:{RestPort}/api/v1/health");
                return resp.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        // Shared by the manual Check-for-Updates flow and the automatic
        // background check so both run the exact same command.
        private ProcessStartInfo FpUpdateJsonPsi() => new ProcessStartInfo
        {
            FileName = "wsl.exe",
            // Path inside WSL: $HOME/falconpulsar/bin/fp. We resolve
            // $HOME inside the WSL distro because the user that owns
            // the install may differ from the Windows username.
            // `fp update --json` (no `--check` flag — check is the
            // default mode of `fp update`; the binary only knows
            // `--apply` and `--json`).
            Arguments = $"-d {_distro} -- bash -lc \"$HOME/falconpulsar/bin/fp update --json 2>/dev/null\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        /// <summary>
        /// "Check for Updates..." menu handler. Shells out to
        /// `fp update --json` inside WSL (check is the default mode; the
        /// same fp binary the installer placed at ~/falconpulsar/bin/fp),
        /// parses the JSON, and either tells the operator everything is up to date,
        /// prompts them to apply detected updates, or surfaces a
        /// registry-connectivity error.
        ///
        /// Apply path opens a Windows Terminal window running
        /// `fp update --apply` inside WSL so the operator can see
        /// streaming progress (image pulls, healthcheck waits). A silent
        /// background apply is wrong UX for an update flow — operators
        /// want to see what's happening, especially in industrial
        /// settings where unattended restarts can disrupt processes.
        /// </summary>
        private async Task CheckForUpdatesAsync()
        {
            string json;
            try
            {
                using var proc = Process.Start(FpUpdateJsonPsi())!;
                json = await proc.StandardOutput.ReadToEndAsync();
                await proc.WaitForExitAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Failed to run fp update: {ex.Message}",
                    "Check for Updates",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (string.IsNullOrWhiteSpace(json))
            {
                MessageBox.Show(
                    "fp CLI not found inside WSL, or fp update returned no output.\n\n" +
                    "Re-run the installer to install the CLI, then try again.",
                    "Check for Updates",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Parse the JSON. We avoid pulling in System.Text.Json to keep
            // the tray app dependency-free; the JSON shape is small enough
            // that a minimal hand-rolled extractor is acceptable. If this
            // grows we can switch.
            UpdateCheckSummary summary;
            try
            {
                summary = ParseUpdateCheckJson(json);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Couldn't parse update status: {ex.Message}\n\n" +
                    "Run `fp update --json` from a terminal for raw output.",
                    "Check for Updates",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // The tray knows its own version natively — the fp CLI only
            // reports its own row, so we append ours client-side before
            // rendering (contract for the host_components section).
            AppendTrayHostRow(summary);

            // A manual check refreshes the passive indicator too, so the
            // tray badge self-clears once everything is up to date again.
            SetPassiveUpdateIndicator(summary);
            UpdateUI();

            // Build the per-component summary line for the dialog body.
            // The loop renders whatever components[] contains, so the
            // optional "AI Engine" image row (engine-enabled installs
            // only) needs no special casing here.
            var lines = new List<string>
            {
                $"Registry: {summary.Registry}   Tag: {summary.Tag}",
                ""
            };
            foreach (var c in summary.Components)
            {
                if (!string.IsNullOrEmpty(c.ErrorKind))
                    lines.Add($"  ⚠  {c.Name}: {c.ErrorKind}");
                else if (c.UpdateAvailable)
                    lines.Add($"  ↑  {c.Name}: update available");
                else if (string.IsNullOrEmpty(c.LocalDigest))
                    lines.Add($"  –  {c.Name}: container not running");
                else
                    lines.Add($"  ✓  {c.Name}: up to date");
            }

            // Host section — present only when the fp CLI is new enough to
            // report host_components (older binaries: omitted entirely).
            // Row wording matches the macOS menu bar app: "✓ X: up to
            // date" / "↑ X: vY available" / "? X: unknown — no internet
            // access".
            if (summary.HostComponents.Count > 0)
            {
                lines.Add("");
                lines.Add("Host components:");
                foreach (var h in summary.HostComponents)
                {
                    var latest = NormalizeVersion(h.LatestVersion);
                    if (!string.IsNullOrEmpty(h.ErrorKind))
                        lines.Add($"  ?  {h.Name}: unknown — no internet access");
                    else if (!IsRealVersion(latest))
                        // Probe succeeded but no release exists yet ("none")
                        // — match the Go CLI/TUI rendering: up to date.
                        lines.Add($"  ✓  {h.Name}: up to date");
                    else if (h.UpdateAvailable)
                        lines.Add($"  ↑  {h.Name}: v{latest} available");
                    else
                        lines.Add($"  ✓  {h.Name}: up to date");
                }
            }
            string body = string.Join("\n", lines);

            // One info line when a host update exists; the actual apply is
            // always the user downloading + running the new installer —
            // nothing here (or anywhere) applies host updates automatically.
            string hostInfo = summary.HostAny
                ? "\n\nHost components (fp CLI, tray app) update via the latest installer."
                : "";

            if (summary.AnyError)
            {
                var res = MessageBox.Show(
                    body + hostInfo +
                    "\n\nRegistry probe failed (often: expired credentials).\n" +
                    "The installer can re-authenticate. Run it now?",
                    "Registry probe failed",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (res == DialogResult.OK)
                    OpenApplyTerminal();
                return;
            }

            if (summary.Any)
            {
                // Container updates available. Prompt to apply. (v1: same
                // prompt regardless of FP_UPDATE_MODE because auto-mode in
                // v1 only fires when the tray app is open, and showing a
                // confirmation with a 30s countdown isn't worth the extra
                // UI complexity for this commit. The user explicitly opens
                // this menu — that's a manual click.)
                var applyRes = MessageBox.Show(
                    body + hostInfo + "\n\nApply container updates now?",
                    "Update available",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (applyRes == DialogResult.Yes)
                    OpenApplyTerminal();
                // Host updates ride the installer, not fp update --apply —
                // offer the releases page separately.
                if (summary.HostAny)
                    OfferInstallerReleasePage(summary);
                return;
            }

            if (summary.HostAny)
            {
                // Only host components are out of date. Never auto-apply, but
                // make the update action the obvious one: OK ("Download
                // Update") fetches the RIGHT file directly and the text spells
                // out the two steps to apply it — so the user never has to
                // pick a file off the releases page or guess how to install.
                var ver = NormalizeVersion(HostLatestVersion(summary));
                var title = string.IsNullOrEmpty(ver)
                    ? "Update available" : $"Update available: v{ver}";
                var res = MessageBox.Show(
                    body +
                    "\n\nTo update this app and the fp command:" +
                    "\n  1.  Click OK — it downloads FalconPulsar-Setup.exe." +
                    "\n  2.  Run the downloaded installer." +
                    "\n  3.  Choose Upgrade — your data and settings are preserved.",
                    title,
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
                if (res == DialogResult.OK)
                    OpenInstallerDownload(summary);
                return;
            }

            MessageBox.Show(body, "All components are up to date",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        /// <summary>
        /// Follow-up prompt used when container updates and a host update
        /// arrive together: the container dialog handles the apply, this
        /// one offers the installer releases page for the host side.
        /// </summary>
        private void OfferInstallerReleasePage(UpdateCheckSummary summary)
        {
            var res = MessageBox.Show(
                "A newer installer release is also available.\n\n" +
                "Open the installer releases page in your browser?",
                "Installer update available",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (res == DialogResult.OK)
                OpenInstallerReleasePage(summary);
        }

        // Opens installer_release_url from the fp JSON in the default
        // browser, falling back to the canonical releases page. https-only
        // as defense in depth: the URL crossed a JSON boundary.
        private void OpenInstallerReleasePage(UpdateCheckSummary summary)
        {
            const string fallback =
                "https://github.com/FalconPulsar/falconpulsar-installer/releases";
            var url = summary.InstallerReleaseUrl;
            if (string.IsNullOrEmpty(url) ||
                !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                url = fallback;
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        // Opens the DIRECT download of the Windows installer for the latest
        // version, so the user never has to choose a file from the releases
        // page. FalconPulsar-Setup.exe is a stable, unversioned asset name
        // present on every release; only the tag in the path varies. Falls
        // back to the releases page when we have no concrete version. The
        // browser (signed in to GitHub) downloads it — the tray can't fetch a
        // private release asset itself. https-only as defense in depth.
        private void OpenInstallerDownload(UpdateCheckSummary summary)
        {
            const string releasesFallback =
                "https://github.com/FalconPulsar/falconpulsar-installer/releases";
            var releaseBase = summary.InstallerReleaseUrl;
            if (string.IsNullOrEmpty(releaseBase) ||
                !releaseBase.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                releaseBase = releasesFallback;

            var ver = NormalizeVersion(HostLatestVersion(summary));
            var url = string.IsNullOrEmpty(ver)
                ? releaseBase
                : $"{releaseBase}/download/v{ver}/FalconPulsar-Setup.exe";
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        /// <summary>
        /// Open Windows Terminal (or fall back to wt.exe via cmd) running
        /// `fp update --apply` inside WSL. The terminal window stays open so
        /// the operator can read output and any healthcheck failures.
        /// </summary>
        private void OpenApplyTerminal()
        {
            // wt.exe is the modern Windows Terminal launcher; if it's not
            // installed, fall back to cmd.exe. Either way the WSL
            // command launches `fp update --apply` and waits.
            var wtArgs = $"-d {_distro} -- bash -lc \"$HOME/falconpulsar/bin/fp update --apply; echo; echo 'Done. Press Enter to close.'; read\"";
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "wt.exe",
                    Arguments = $"wsl.exe {wtArgs}",
                    UseShellExecute = true
                });
            }
            catch
            {
                // wt.exe not available — fall back to direct wsl.exe.
                // It'll open the default console, which is fine.
                Process.Start(new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = wtArgs,
                    UseShellExecute = true
                });
            }
        }

        /// <summary>
        /// Minimal hand-rolled JSON extractor for the fp update --json
        /// output. Avoids System.Text.Json dependency to keep tray app
        /// build deps minimal. The schema is small and fixed; if it grows
        /// we should switch to a real JSON library.
        /// </summary>
        private static UpdateCheckSummary ParseUpdateCheckJson(string json)
        {
            // System.Text.Json is part of the .NET BCL — no extra
            // package needed, no third-party deps to manage.
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var summary = new UpdateCheckSummary
            {
                Registry = root.TryGetProperty("registry", out var r) ? r.GetString() ?? "" : "",
                Tag = root.TryGetProperty("tag", out var t) ? t.GetString() ?? "" : "",
                Any = root.TryGetProperty("any_update_available", out var a) && a.GetBoolean(),
                AnyError = root.TryGetProperty("any_probe_failed", out var e) && e.GetBoolean(),
                Components = new List<ComponentSummary>(),
                // Host-component fields, added alongside the tray's
                // FP_UPDATE_CHECK_AUTO support. All optional so output
                // from an older fp binary still parses (TryGetProperty
                // simply misses and the defaults hold).
                HostAny = root.TryGetProperty("host_any_update_available", out var ha) && ha.GetBoolean(),
                HostProbeFailed = root.TryGetProperty("host_probe_failed", out var hp) && hp.GetBoolean(),
                InstallerReleaseUrl = root.TryGetProperty("installer_release_url", out var iru) ? iru.GetString() ?? "" : "",
                HostComponents = new List<HostComponentSummary>()
            };
            if (root.TryGetProperty("components", out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                foreach (var c in arr.EnumerateArray())
                {
                    summary.Components.Add(new ComponentSummary
                    {
                        Name = c.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "",
                        ImageRef = c.TryGetProperty("image_ref", out var ir) ? ir.GetString() ?? "" : "",
                        LocalDigest = c.TryGetProperty("local_digest", out var ld) ? ld.GetString() ?? "" : "",
                        RemoteDigest = c.TryGetProperty("remote_digest", out var rd) ? rd.GetString() ?? "" : "",
                        UpdateAvailable = c.TryGetProperty("update_available", out var ua) && ua.GetBoolean(),
                        ErrorKind = c.TryGetProperty("error_kind", out var ek) ? ek.GetString() ?? "" : "",
                        Error = c.TryGetProperty("error", out var er) ? er.GetString() ?? "" : ""
                    });
                }
            }
            if (root.TryGetProperty("host_components", out var harr) && harr.ValueKind == JsonValueKind.Array)
            {
                foreach (var h in harr.EnumerateArray())
                {
                    summary.HostComponents.Add(new HostComponentSummary
                    {
                        Name = h.TryGetProperty("name", out var hn) ? hn.GetString() ?? "" : "",
                        InstalledVersion = h.TryGetProperty("installed_version", out var hi) ? hi.GetString() ?? "" : "",
                        LatestVersion = h.TryGetProperty("latest_version", out var hl) ? hl.GetString() ?? "" : "",
                        UpdateAvailable = h.TryGetProperty("update_available", out var hu) && hu.GetBoolean(),
                        ErrorKind = h.TryGetProperty("error_kind", out var hek) ? hek.GetString() ?? "" : "",
                        Error = h.TryGetProperty("error", out var her) ? her.GetString() ?? "" : ""
                    });
                }
            }
            return summary;
        }

        private class UpdateCheckSummary
        {
            public string Registry { get; set; } = "";
            public string Tag { get; set; } = "";
            public bool Any { get; set; }
            public bool AnyError { get; set; }
            public List<ComponentSummary> Components { get; set; } = new();
            // Host-component section (fp CLI + this tray). Empty/false
            // when the fp binary predates host_components.
            public bool HostAny { get; set; }
            public bool HostProbeFailed { get; set; }
            public string InstallerReleaseUrl { get; set; } = "";
            public List<HostComponentSummary> HostComponents { get; set; } = new();
        }

        private class ComponentSummary
        {
            public string Name { get; set; } = "";
            public string ImageRef { get; set; } = "";
            public string LocalDigest { get; set; } = "";
            public string RemoteDigest { get; set; } = "";
            public bool UpdateAvailable { get; set; }
            public string ErrorKind { get; set; } = "";
            public string Error { get; set; } = "";
        }

        private class HostComponentSummary
        {
            public string Name { get; set; } = "";
            public string InstalledVersion { get; set; } = "";
            public string LatestVersion { get; set; } = "";
            public bool UpdateAvailable { get; set; }
            public string ErrorKind { get; set; } = "";   // "" | "unreachable"
            public string Error { get; set; } = "";
        }

        /// <summary>
        /// Appends this tray's own row to the host section. The fp CLI only
        /// reports its own compiled-in version; each tray adds its row
        /// client-side because it knows its version natively, reusing
        /// latest_version from the fp row (all host components version
        /// together with the installer release). No-op when the fp binary
        /// predates host_components — there is no latest to compare against.
        /// </summary>
        private static void AppendTrayHostRow(UpdateCheckSummary summary)
        {
            if (summary.HostComponents.Count == 0) return;
            var fpRow = summary.HostComponents[0];
            var installed = TrayProductVersion;
            var latest = NormalizeVersion(fpRow.LatestVersion);
            // Contract: update_available = (normalized installed !=
            // normalized latest) && latest is a real version. "Real"
            // excludes "", "none" and unreachable probes.
            var avail = IsRealVersion(latest)
                && !HostVersionsEquivalent(installed, latest);
            summary.HostComponents.Add(new HostComponentSummary
            {
                Name = "Tray app",
                InstalledVersion = installed,
                LatestVersion = fpRow.LatestVersion,
                UpdateAvailable = avail,
                // Propagate the fp row's probe failure so this row renders
                // as unreachable too instead of a bogus "up to date".
                ErrorKind = fpRow.ErrorKind,
                Error = ""
            });
            if (avail) summary.HostAny = true;
        }

        // Latest installer version as reported by the fp CLI's host row
        // (raw, possibly "v"-prefixed or "none"; "" when absent).
        private static string HostLatestVersion(UpdateCheckSummary summary) =>
            summary.HostComponents.Count > 0
                ? summary.HostComponents[0].LatestVersion
                : "";

        // Strips a leading "v" and any "+<build-metadata>" suffix (the
        // .NET 8 SDK appends "+<git-sha>" to InformationalVersion when
        // building inside a git checkout, which CI does).
        private static string NormalizeVersion(string v)
        {
            if (string.IsNullOrWhiteSpace(v)) return "";
            var s = v.Trim();
            var plus = s.IndexOf('+');
            if (plus >= 0) s = s.Substring(0, plus);
            if (s.StartsWith("v", StringComparison.OrdinalIgnoreCase))
                s = s.Substring(1);
            return s;
        }

        // A comparable release version: non-empty, not the feed's "none"
        // placeholder (pre-release repos), starts with a digit.
        private static bool IsRealVersion(string normalized) =>
            normalized.Length > 0
            && !normalized.Equals("none", StringComparison.OrdinalIgnoreCase)
            && char.IsDigit(normalized[0]);

        // CI strips pre-release suffixes from the tray's version because
        // System.Version can't represent "-alpha.N" — a release-tagged tray
        // only knows "0.1.4" while the latest-release feed says
        // "0.1.4-alpha.28". When our own version carries no pre-release
        // suffix, also accept a match on the latest's numeric core so we
        // don't flag a permanent false "update available" on ourselves.
        // (The fp CLI row keeps full-precision comparison: Go compiles the
        // complete tag in via ldflags.)
        private static bool HostVersionsEquivalent(string installed, string latest)
        {
            if (installed == latest) return true;
            if (!installed.Contains('-'))
            {
                var dash = latest.IndexOf('-');
                var core = dash >= 0 ? latest.Substring(0, dash) : latest;
                if (installed == core) return true;
            }
            return false;
        }

        /// <summary>
        /// Records the passive "update available" state consumed by
        /// UpdateUI (tray tooltip suffix + hidden menu row). Passive only:
        /// no popups, no downloads — the menu row opens the normal
        /// Check-for-Updates flow when clicked.
        /// </summary>
        private void SetPassiveUpdateIndicator(UpdateCheckSummary summary)
        {
            // A DEFINITE update badges the icon even when another
            // component's probe failed — matches the macOS menu bar app
            // (suppressing a real update signal is the worse failure).
            var containerUpdates = summary.Any;
            _updateAvailable = containerUpdates || summary.HostAny;
            // "Update available: vX" carries the installer version when the
            // host side is what's stale; container updates are digest-based
            // (no single version), so the row stays generic for those.
            _updateAvailableVersion = summary.HostAny
                ? NormalizeVersion(HostLatestVersion(summary))
                : "";
        }

        // ── Automatic update checking (FP_UPDATE_CHECK_AUTO) ────────────

        /// <summary>
        /// Arms or disarms the background update-check timers to match
        /// FP_UPDATE_CHECK_AUTO. ON: one check ~2 minutes after launch,
        /// then at most one per 24h (an hourly gate re-tests the spacing so
        /// a sleeping machine doesn't burst missed ticks). OFF (default):
        /// both timers disposed — zero background update traffic. Called
        /// from the constructor, every health poll (picks up hand-edits of
        /// .env) and the menu toggle.
        /// </summary>
        private void EnsureAutoUpdateTimers()
        {
            if (_updateCheckAutoEnabled)
            {
                if (_updateDailyTimer != null) return;   // already armed

                _updateInitialTimer = new System.Windows.Forms.Timer { Interval = 2 * 60 * 1000 };
                _updateInitialTimer.Tick += async (s, e) =>
                {
                    _updateInitialTimer?.Stop();
                    await RunAutoUpdateCheckAsync();
                };
                _updateInitialTimer.Start();

                _updateDailyTimer = new System.Windows.Forms.Timer { Interval = 60 * 60 * 1000 };
                _updateDailyTimer.Tick += async (s, e) =>
                {
                    if (DateTime.UtcNow - _lastAutoUpdateCheck >= TimeSpan.FromHours(24))
                        await RunAutoUpdateCheckAsync();
                };
                _updateDailyTimer.Start();
            }
            else
            {
                _updateInitialTimer?.Stop();
                _updateInitialTimer?.Dispose();
                _updateInitialTimer = null;
                _updateDailyTimer?.Stop();
                _updateDailyTimer?.Dispose();
                _updateDailyTimer = null;
            }
        }

        /// <summary>
        /// Background update check: same `fp update --json` as the manual
        /// flow, but strictly passive — on updates it only flips the tray
        /// tooltip indicator and the "Update available: vX" menu row; every
        /// failure is swallowed silently. Never applies anything.
        /// </summary>
        private async Task RunAutoUpdateCheckAsync()
        {
            if (_autoUpdateCheckRunning) return;
            // Re-test the flag right before doing any work — it may have
            // been switched off since the timer was armed.
            if (!_updateCheckAutoEnabled) return;
            _autoUpdateCheckRunning = true;
            try
            {
                _lastAutoUpdateCheck = DateTime.UtcNow;
                string json;
                try
                {
                    using var proc = Process.Start(FpUpdateJsonPsi())!;
                    json = await proc.StandardOutput.ReadToEndAsync();
                    await proc.WaitForExitAsync();
                }
                catch
                {
                    return;   // passive: no error surfaces
                }
                if (string.IsNullOrWhiteSpace(json)) return;

                UpdateCheckSummary summary;
                try { summary = ParseUpdateCheckJson(json); }
                catch { return; }

                AppendTrayHostRow(summary);
                SetPassiveUpdateIndicator(summary);
                UpdateUI();
            }
            finally
            {
                _autoUpdateCheckRunning = false;
            }
        }

        /// <summary>
        /// Menu toggle for FP_UPDATE_CHECK_AUTO. The write runs inside WSL
        /// (the .env belongs to the distro user; sed -i and >> both keep
        /// the file's permissions, and running as the distro's default
        /// user keeps ownership) and only ever replaces the
        /// FP_UPDATE_CHECK_AUTO= line in place or appends one — no other
        /// line is touched. Reading stays on the shared EnvValue helper.
        /// </summary>
        private async Task ToggleUpdateCheckAutoAsync()
        {
            var enable = !_updateCheckAutoEnabled;
            var val = enable ? "true" : "false";
            // Replace-or-append one-liner. The tail -c1 test appends a
            // newline first when the file doesn't end in one, so we never
            // glue onto someone's last line.
            var script =
                "f='" + _wslHome + "/.env'\n" +
                "if [ -f \"$f\" ] && grep -q '^FP_UPDATE_CHECK_AUTO=' \"$f\"; then\n" +
                "  sed -i 's/^FP_UPDATE_CHECK_AUTO=.*/FP_UPDATE_CHECK_AUTO=" + val + "/' \"$f\"\n" +
                "else\n" +
                "  if [ -f \"$f\" ] && [ -s \"$f\" ] && [ -n \"$(tail -c1 \"$f\")\" ]; then printf '\\n' >> \"$f\"; fi\n" +
                "  printf 'FP_UPDATE_CHECK_AUTO=" + val + "\\n' >> \"$f\"\n" +
                "fi\n";
            var (rc, _) = await RunWslBashCaptureAsync(script);
            if (rc != 0)
            {
                ShowNotification("Settings not saved",
                    "Couldn't update FP_UPDATE_CHECK_AUTO in the stack .env.",
                    ToolTipIcon.Warning);
                return;
            }

            // Re-read from .env so the checkbox reflects what actually
            // landed, then arm/disarm the timers to match.
            _updateCheckAutoEnabled = UpdateCheckAutoEnabled;
            _autoUpdateCheckItem.Checked = _updateCheckAutoEnabled;
            EnsureAutoUpdateTimers();
        }

        // Profile flags for every compose invocation. --profile ai: legacy
        // compose compat (pre-mandatory-gateway installs put ai-gateway
        // behind a profile); no-op on current stacks. --profile engine is
        // added when FP_AI_ENGINE_ENABLED=true: a --profile flag on the CLI
        // OVERRIDES COMPOSE_PROFILES from .env, so without it Start/Stop/
        // Restart/Logs would silently skip the AI Engine on engine-enabled
        // installs.
        private string ComposeProfileArgs
        {
            get
            {
                var args = "--profile ai";
                if (EngineEnabled) args += " --profile engine";
                if (CopilotEnabled) args += " --profile copilot";
                return args;
            }
        }

        private async Task RunComposeCommand(string command)
        {
            _trayIcon.Icon = CreateStatusIcon(Color.FromArgb(234, 179, 8), _updateAvailable);
            _trayIcon.Text = "FalconPulsar: Working...";
            _startItem.Enabled = false;
            _stopItem.Enabled = false;
            _restartItem.Enabled = false;

            try
            {
                // Profile flags (legacy ai + optional engine): see
                // ComposeProfileArgs.
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {_distro} -- docker compose -f {_composePath} {ComposeProfileArgs} {command}",
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                await proc.WaitForExitAsync();

                // Wait a moment for containers to settle, then refresh
                await Task.Delay(3000);
                await PollHealth();
            }
            catch (Exception ex)
            {
                ShowNotification("Error", $"Failed to run: {ex.Message}", ToolTipIcon.Error);
                await PollHealth();
            }
        }

        /// <summary>
        /// Every destination is a route in the unified shell.
        ///
        /// These used to open the surfaces on their own ports, which was right
        /// when they were three separate applications. They are now embedded,
        /// and reaching one directly means arriving without the shell around
        /// it: no mode switcher, no alarm lane, no identity, and an app waiting
        /// on a handshake from a parent frame that is not there.
        ///
        /// The health polling still uses EnginePort and CopilotPort. That is a
        /// check on the service, and belongs where the service actually lives.
        /// </summary>
        private void OpenShell(string path = "")
        {
            Process.Start(new ProcessStartInfo($"http://localhost:{UiPort}{path}")
            { UseShellExecute = true });
        }

        private void OpenWebUI() => OpenShell();

        private void OpenAiEngine() => OpenShell("/agents");

        private void OpenCopilot() => OpenShell("/workplace");

        private void ViewLogs()
        {
            // Profile flags (legacy ai + optional engine): see
            // ComposeProfileArgs.
            Process.Start(new ProcessStartInfo
            {
                FileName = "wsl.exe",
                Arguments = $"-d {_distro} -- docker compose -f {_composePath} {ComposeProfileArgs} logs -f --tail 100",
                UseShellExecute = true
            });
        }

        private void OpenDataFolder()
        {
            Process.Start(new ProcessStartInfo("explorer.exe", _wslHomeUnc)
            { UseShellExecute = true });
        }

        private void EditConfigFile(string filename)
        {
            // Config files live inside the WSL distro at the resolved stack dir.
            var wslPath = Path.Combine(_wslHomeUnc, filename.Replace('/', '\\'));
            if (File.Exists(wslPath))
            {
                Process.Start(new ProcessStartInfo("notepad.exe", wslPath)
                { UseShellExecute = true });
            }
            else
            {
                ShowNotification("File not found",
                    $"{filename} not found at {wslPath}", ToolTipIcon.Warning);
            }
        }

        private void OpenInstallLog()
        {
            var logPath = Path.Combine(Path.GetTempPath(), "falconpulsar-install.log");
            if (File.Exists(logPath))
                Process.Start(new ProcessStartInfo("notepad.exe", logPath)
                { UseShellExecute = true });
        }

        private bool IsAutoStartEnabled()
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", false);
            return key?.GetValue("FalconPulsar") != null;
        }

        private void ToggleAutoStart()
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true);
            if (key == null) return;

            if (IsAutoStartEnabled())
            {
                key.DeleteValue("FalconPulsar", false);
                _autoStartItem.Checked = false;
            }
            else
            {
                var exePath = Application.ExecutablePath;
                key.SetValue("FalconPulsar", $"\"{exePath}\"");
                _autoStartItem.Checked = true;
            }
        }

        private void ShowNotification(string title, string text, ToolTipIcon icon)
        {
            _trayIcon.BalloonTipTitle = title;
            _trayIcon.BalloonTipText = text;
            _trayIcon.BalloonTipIcon = icon;
            _trayIcon.ShowBalloonTip(5000);
        }

        private Bitmap _falconLogo;

        private Bitmap GetFalconLogo()
        {
            if (_falconLogo == null)
            {
                var asm = System.Reflection.Assembly.GetExecutingAssembly();
                using var stream = asm.GetManifestResourceStream("falcon-logo.png");
                if (stream != null)
                    _falconLogo = new Bitmap(stream);
            }
            return _falconLogo;
        }

        private Icon CreateStatusIcon(Color statusColor, bool updateAvailable = false)
        {
            const int size = 32;
            const int dotSize = 12;
            var bmp = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.Clear(Color.Transparent);

                // Draw the falcon logo scaled to fit
                var logo = GetFalconLogo();
                if (logo != null)
                {
                    g.DrawImage(logo, 0, 0, size, size);
                }
                else
                {
                    // Fallback if logo resource is missing
                    using var fallbackBrush = new SolidBrush(Color.FromArgb(14, 26, 49));
                    g.FillEllipse(fallbackBrush, 2, 2, size - 4, size - 4);
                    using var font = new Font("Segoe UI", 14, FontStyle.Bold);
                    using var textBrush = new SolidBrush(Color.White);
                    var sf = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    g.DrawString("F", font, textBrush, new RectangleF(0, 0, size, size), sf);
                }

                // Draw a small status dot in the bottom-right corner
                int dotX = size - dotSize - 1;
                int dotY = size - dotSize - 1;
                // White border around the dot for visibility
                using var borderBrush = new SolidBrush(Color.White);
                g.FillEllipse(borderBrush, dotX - 1, dotY - 1, dotSize + 2, dotSize + 2);
                // Colored status dot
                using var dotBrush = new SolidBrush(statusColor);
                g.FillEllipse(dotBrush, dotX, dotY, dotSize, dotSize);

                // "Update available" badge: a distinct BLUE dot at the TOP-right
                // corner (the health dot above stays bottom-right and keeps its
                // own meaning). Mirrors the macOS menu-bar app's blue update dot
                // so a new release is visible on the icon itself, not just the
                // menu text. Driven by _updateAvailable, so every 15s health
                // refresh keeps it painted until the update is applied.
                if (updateAvailable)
                {
                    int upX = size - dotSize - 1;
                    int upY = 1;
                    using var upBorder = new SolidBrush(Color.White);
                    g.FillEllipse(upBorder, upX - 1, upY - 1, dotSize + 2, dotSize + 2);
                    using var upBrush = new SolidBrush(Color.FromArgb(0, 122, 255)); // macOS systemBlue
                    g.FillEllipse(upBrush, upX, upY, dotSize, dotSize);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        private Image CreateDot(Color color)
        {
            var bmp = new Bitmap(12, 12);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using var brush = new SolidBrush(color);
                g.FillEllipse(brush, 1, 1, 10, 10);
            }
            return bmp;
        }

        private void ShowAbout()
        {
            var aboutForm = new Form
            {
                Text = "About FalconPulsar",
                ClientSize = new Size(540, 528),
                StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                BackColor = Color.FromArgb(8, 18, 36)
            };

            // Gradient panel
            var panel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.Transparent
            };
            panel.Paint += (s, e) =>
            {
                using var brush = new System.Drawing.Drawing2D.LinearGradientBrush(
                    panel.ClientRectangle,
                    Color.FromArgb(16, 38, 76),
                    Color.FromArgb(8, 18, 36),
                    System.Drawing.Drawing2D.LinearGradientMode.Vertical);
                e.Graphics.FillRectangle(brush, panel.ClientRectangle);
            };
            aboutForm.Controls.Add(panel);

            // Logo — large hero
            var logo = GetFalconLogo();
            if (logo != null)
            {
                var imgBox = new PictureBox
                {
                    Image = new Bitmap(logo, new Size(140, 140)),
                    Size = new Size(140, 140),
                    Location = new Point(200, 20),
                    BackColor = Color.Transparent,
                    SizeMode = PictureBoxSizeMode.Zoom
                };
                panel.Controls.Add(imgBox);
            }

            // Title
            panel.Controls.Add(new Label
            {
                Text = "FalconPulsar",
                Font = new Font("Segoe UI", 26, FontStyle.Bold),
                ForeColor = Color.White,
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(540, 40),
                Location = new Point(0, 170),
                TextAlign = ContentAlignment.MiddleCenter
            });

            // Version pill
            //
            // "QuickDock", matching macOS: this window belongs to the tray
            // app, not to the installer. The number is still the distribution
            // version — the tray ships from the same VERSION file.
            //
            // The pill MEASURES its text rather than assuming a width. At a
            // fixed 150px the longer label would sit wider than its own
            // container and the panel edges would show through the middle of
            // the words, which is exactly how the macOS one looked wrong.
            var verFont = new Font("Consolas", 10);
            var verText = $"QuickDock  v{TrayProductVersion}";
            int verTextW = TextRenderer.MeasureText(verText, verFont).Width;
            int pillW = verTextW + 28;   // 14px of breathing room each side
            var verPanel = new Panel
            {
                Size = new Size(pillW, 26),
                Location = new Point((540 - pillW) / 2, 215),
                BackColor = Color.FromArgb(30, 255, 255, 255)
            };
            verPanel.Paint += (s, e) =>
            {
                e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using var brush = new SolidBrush(Color.FromArgb(25, 255, 255, 255));
                e.Graphics.FillRectangle(brush, 0, 0, pillW, 26);
            };
            panel.Controls.Add(verPanel);
            verPanel.Controls.Add(new Label
            {
                Text = verText,
                Font = verFont,
                ForeColor = Color.FromArgb(200, 200, 200),
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(pillW, 26),
                TextAlign = ContentAlignment.MiddleCenter
            });

            // Component grid with checkmarks. Each component shows its real
            // version (from OCI labels via docker inspect) plus a 7-char
            // build-identifier suffix so support requests pin the exact
            // build. Compose row reads the real engine version from
            // `docker compose version --short` instead of the static "v2".
            // Gather per-container versions OFF the UI thread. GetContainerInfo /
            // GetComposeVersion block on WSL via
            // RunWslBashCaptureAsync(...).GetAwaiter().GetResult() — running that
            // sync-over-async on the UI thread deadlocks/freezes the whole tray
            // and the About window never appears when WSL is slow or busy.
            // Offload to a worker and cap the wait so About ALWAYS opens; the
            // version cells show "…" if WSL didn't answer in time.
            var coreInfo = new ContainerInfo { Version = "…", Revision = string.Empty };
            var uiInfo = coreInfo;
            var gwInfo = coreInfo;
            var engInfo = coreInfo;
            var copInfo = coreInfo;
            var composeVer = "…";
            bool copilot = CopilotEnabled;
            try
            {
                ContainerInfo c = default, u = default, g = default, e = default, cp = default;
                string cv = string.Empty;
                var gather = Task.Run(() =>
                {
                    c  = GetContainerInfo("falconpulsar-core");
                    u  = GetContainerInfo("falconpulsar-ui");
                    g  = GetContainerInfo("falconpulsar-ai-gateway");
                    e  = GetContainerInfo("falconpulsar-ai-engine");
                    if (copilot) cp = GetContainerInfo("falconpulsar-copilot");
                    cv = GetComposeVersion();
                });
                if (gather.Wait(4000))
                {
                    coreInfo = c; uiInfo = u; gwInfo = g; engInfo = e; copInfo = cp; composeVer = cv;
                }
            }
            catch { /* leave the "…" placeholders — never let About hang */ }

            // AI Engine is standard; Command Center appears when the install opted in.
            var namesList = new System.Collections.Generic.List<string> { "Core Engine", "Compose", "Web UI", "AI Capabilities", "AI Engine" };
            var versList  = new System.Collections.Generic.List<string> { coreInfo.DisplayString, composeVer, uiInfo.DisplayString, gwInfo.DisplayString, engInfo.DisplayString };
            var oksList   = new System.Collections.Generic.List<bool>   { _coreRunning, true, _uiRunning, _gatewayRunning, _engineRunning };
            if (copilot)
            {
                namesList.Add("Command Center"); versList.Add(copInfo.DisplayString); oksList.Add(_copilotRunning);
            }
            string[] names = namesList.ToArray();
            string[] vers  = versList.ToArray();
            bool[] oks     = oksList.ToArray();

            // 2x2 grid of 2-line cells. Each cell:
            //
            //   \u2713  Core Engine                   \u2190 top line: check + name (label)
            //      0.1.0-alpha.1 (58b896f)       \u2190 bottom line: version (data)
            //
            // Previous layout put name and version on the same line, which
            // worked when versions were short ("latest", "v2") but truncated
            // and overflowed the next column the moment we started rendering
            // real semvers + revision SHAs. Two-line cells give the version
            // string the entire column width to render in.
            //
            // colW = 240, name + version both indent to cx+22 (under the
            // check), each gets 200px width \u2014 leaves an 18px safety gap to
            // the next column's check icon. Same shape as the macOS About
            // panel for cross-platform consistency.
            int gridY = 260;
            const int rowH = 48;     // was 30 (single-line); 48 fits 2 stacked Labels with breathing room
            const int lineGap = 22;  // vertical distance between the two lines within a cell
            for (int i = 0; i < names.Length; i++)
            {
                int col = i % 2;
                int row = i / 2;
                int cx = 45 + col * 240;
                int cy = gridY + row * rowH;

                // \u2500\u2500 Top line: check + name \u2500\u2500
                panel.Controls.Add(new Label
                {
                    Text = oks[i] ? "\u2713" : "\u2717",
                    Font = new Font("Segoe UI", 12, FontStyle.Bold),
                    ForeColor = oks[i] ? Color.FromArgb(34, 197, 94) : Color.FromArgb(239, 68, 68),
                    BackColor = Color.Transparent,
                    AutoSize = false,
                    Size = new Size(20, 20),
                    Location = new Point(cx, cy)
                });

                // No trailing colon \u2014 the version below stands on its own
                // line, so the "Name: <inline value>" punctuation no
                // longer makes sense.
                panel.Controls.Add(new Label
                {
                    Text = names[i],
                    Font = new Font("Segoe UI", 10),
                    ForeColor = Color.FromArgb(170, 170, 170),
                    BackColor = Color.Transparent,
                    AutoSize = false,
                    Size = new Size(200, 20),
                    Location = new Point(cx + 22, cy)
                });

                // \u2500\u2500 Bottom line: version (indented under name) \u2500\u2500
                // 200px width fits "a.b.c-rc.10 (1234567)" (~22 chars) at
                // Consolas 9pt with a comfortable buffer to the next
                // column \u2014 no truncation, no overflow.
                panel.Controls.Add(new Label
                {
                    Text = vers[i],
                    Font = new Font("Consolas", 9),
                    ForeColor = Color.FromArgb(220, 220, 220),
                    BackColor = Color.Transparent,
                    AutoSize = false,
                    Size = new Size(200, 20),
                    Location = new Point(cx + 22, cy + lineGap)
                });
            }

            // Links
            // Below the 2x2 component grid (row 1 version line ends ~y=350);
            // was 340, which overlapped the Web UI / AI Capabilities versions.
            // Derived from the grid so adding a component row (AI Engine is
            // standard now, Command Center is optional) pushes the links and
            // the two footer lines down instead of overlapping the last cell.
            int gridRows = (names.Length + 1) / 2;
            int linksY = gridY + gridRows * rowH + 15;
            var linkData = new[] {
                ("Documentation", "https://falconpulsar.com/docs"),
                ("Release Notes", "https://github.com/FalconPulsar/falconpulsar-installer/releases"),
                ("License", "https://github.com/FalconPulsar/falconpulsar-installer/blob/main/LICENSE")
            };
            for (int i = 0; i < linkData.Length; i++)
            {
                var (text, url) = linkData[i];
                var link = new LinkLabel
                {
                    Text = text,
                    Font = new Font("Segoe UI", 10),
                    LinkColor = Color.FromArgb(90, 165, 255),
                    ActiveLinkColor = Color.FromArgb(130, 190, 255),
                    BackColor = Color.Transparent,
                    AutoSize = true,
                    Location = new Point(60 + i * 165, linksY)
                };
                var u = url;
                link.Click += (s, e) => Process.Start(new ProcessStartInfo(u) { UseShellExecute = true });
                panel.Controls.Add(link);
            }

            // Copyright
            panel.Controls.Add(new Label
            {
                Text = "Copyright (c) 2026 FalconPulsar Contributors. All rights reserved.",
                Font = new Font("Segoe UI", 9),
                ForeColor = Color.FromArgb(100, 100, 100),
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(540, 18),
                Location = new Point(0, linksY + 25),
                TextAlign = ContentAlignment.MiddleCenter
            });

            panel.Controls.Add(new Label
            {
                Text = "Self-host in 3 minutes. Your infrastructure, your data.",
                Font = new Font("Segoe UI", 9),
                ForeColor = Color.FromArgb(90, 90, 90),
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(540, 18),
                Location = new Point(0, linksY + 45),
                TextAlign = ContentAlignment.MiddleCenter
            });

            aboutForm.ShowDialog();
        }

        private void UninstallFalconPulsar()
        {
            // Resolve the Inno Setup uninstaller. Inno's wizard lets the user
            // choose a custom install directory, so the ProgramFiles default is
            // only a fallback -- the authoritative location is the
            // UninstallString value Inno writes at install time. Mirrors the fp
            // CLI's resolveWindowsUninstaller (console/internal/cli/cli.go).
            var uninstExe = ResolveUninstaller();

            if (!string.IsNullOrEmpty(uninstExe) && File.Exists(uninstExe))
            {
                Process.Start(new ProcessStartInfo(uninstExe) { UseShellExecute = true });
            }
            else
            {
                MessageBox.Show(
                    "Uninstaller not found at:\n" + uninstExe + "\n\n" +
                    "You can uninstall from Windows Settings > Apps > FalconPulsar.",
                    "Uninstall FalconPulsar",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }

        // Locate unins000.exe via the Inno Setup UninstallString so a custom
        // install directory is honoured, falling back to the ProgramFiles
        // default when the registry lookup fails. The AppId GUID must match
        // AppId in windows/installer.iss. HKLM because the installer requires
        // admin. Mirrors resolveWindowsUninstaller in the fp CLI.
        private static string ResolveUninstaller()
        {
            const string uninstallSubKey =
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" +
                "{8E0B7C2F-3F4D-4B9E-9C6A-1D5F8A2B9C71}_is1";

            // Try the native 64-bit view then the 32-bit (WOW6432Node) view so
            // the tray app's own bitness doesn't decide which view we read.
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                try
                {
                    using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
                    using var key = baseKey.OpenSubKey(uninstallSubKey);
                    if (key?.GetValue("UninstallString") is string raw && raw.Length > 0)
                    {
                        // Inno writes it quoted: "C:\...\unins000.exe" -- strip
                        // the surrounding quotes (mirrors the fp CLI).
                        var path = raw.Trim().Trim('"');
                        if (!string.IsNullOrEmpty(path) && File.Exists(path))
                            return path;
                    }
                }
                catch
                {
                    // Registry view unavailable / access denied -- try the next
                    // view, then fall through to the ProgramFiles default.
                }
            }

            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "FalconPulsar", "unins000.exe");
        }

        private void ExitApp()
        {
            _pollTimer.Stop();
            _trayIcon.Visible = false;
            Application.Exit();
        }

        // ── WSL helpers (the real stack state lives inside WSL)

        // ── Per-container OCI metadata (About panel) ────────────────────
        // Reads org.opencontainers.image.{version,revision,created} labels
        // from a running container. Mirrors AppDelegate.swift's
        // getContainerInfo on macOS so the About panel content is identical
        // across platforms. When the version label is missing or carries a
        // non-semver placeholder ("main", "master", "develop", "latest"),
        // falls back to a 7-char prefix of the image digest -- always
        // available, cryptographically meaningful, unambiguous.
        private struct ContainerInfo
        {
            public string Version;   // "0.3.7" or "a03db27" (digest fallback)
            public string Revision;  // "0d8f4a2" (short SHA) or empty

            public string DisplayString
            {
                get
                {
                    if (Version == "n/a") return "n/a";
                    if (string.IsNullOrEmpty(Revision)) return Version;
                    if (Version == Revision) return Version;  // digest fallback
                    // A `git describe` version already ends in the revision
                    // (v0.1.4-alpha.89-5-g61ec2ad); appending "(61ec2ad)"
                    // repeats it and overflows the version column.
                    if (Version.Contains(Revision)) return Version;
                    return $"{Version} ({Revision})";
                }
            }
        }

        private ContainerInfo GetContainerInfo(string containerName)
        {
            // Single inspect call returning all 4 fields tab-separated.
            // The 'index' template function returns "" for missing keys, so
            // older or upstream-mislabelled images don't error -- they just
            // route into the digest-fallback branch below.
            const string fmt = "{{ index .Config.Labels \"org.opencontainers.image.version\" }}\\t" +
                               "{{ index .Config.Labels \"org.opencontainers.image.revision\" }}\\t" +
                               "{{ index .Config.Labels \"org.opencontainers.image.created\" }}\\t" +
                               "{{ .Image }}";
            var script = $"docker inspect --format '{fmt}' {containerName} 2>/dev/null";
            var (rc, output) = RunWslBashCaptureAsync(script).GetAwaiter().GetResult();
            // Trim ONLY trailing newlines, NOT all whitespace. Containers
            // without any OCI labels emit "\t\t\t<imageId>" -- string.Trim()
            // would strip the leading tabs, collapsing 4 fields into 1 and
            // putting the image digest where labelVer is supposed to be.
            // Subtle bug, took a live test to surface it.
            output = (output ?? string.Empty).TrimEnd('\n', '\r');
            if (rc != 0 || string.IsNullOrEmpty(output))
            {
                return new ContainerInfo { Version = "n/a", Revision = string.Empty };
            }

            var parts = output.Split('\t');
            var labelVer = parts.Length > 0 ? parts[0] : string.Empty;
            var labelRev = parts.Length > 1 ? parts[1] : string.Empty;
            var imageId  = parts.Length > 3 ? parts[3] : string.Empty;

            // Branch-name placeholders some image builds set instead of
            // a real semver. Treat them as missing -> fall back to digest.
            var placeholders = new HashSet<string> { "", "main", "master", "develop", "latest", "HEAD" };

            string version;
            if (placeholders.Contains(labelVer))
            {
                var id = imageId.StartsWith("sha256:") ? imageId.Substring(7) : imageId;
                version = string.IsNullOrEmpty(id) ? "n/a" : id.Substring(0, Math.Min(7, id.Length));
            }
            else
            {
                version = labelVer;
            }

            // Revision label is a full git SHA (40 chars). Truncate to 7
            // for display, matching every other VCS surface.
            var revision = string.IsNullOrEmpty(labelRev) ? string.Empty
                : labelRev.Substring(0, Math.Min(7, labelRev.Length));

            return new ContainerInfo { Version = version, Revision = revision };
        }

        // Real Docker Compose engine version (e.g. "v2.21.0"), replacing
        // the previously hardcoded "v2" in the About grid. What users
        // actually need to share for compose-related support requests.
        private string GetComposeVersion()
        {
            var (rc, output) = RunWslBashCaptureAsync("docker compose version --short 2>/dev/null").GetAwaiter().GetResult();
            output = (output ?? string.Empty).Trim();
            if (rc != 0 || string.IsNullOrEmpty(output)) return "v2";
            return output.StartsWith("v") ? output : "v" + output;
        }

        private async Task<(int exitCode, string stdout)> RunWslBashCaptureAsync(string script)
        {
            // Run as the distro's default user (which is who owns the stack
            // in per-user installs). No -u override: that would switch to
            // `falconpulsar` which only exists in legacy installs.
            var psi = new ProcessStartInfo
            {
                FileName = "wsl.exe",
                Arguments = $"-d {_distro} -- bash",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // Force UTF-8 on stdin. Without this, .NET defaults to the
                // Windows OEM codepage (CP1252 on en-US). Non-ASCII bytes
                // in the piped bash script (e.g. em-dashes in progress
                // messages) get transliterated to single CP1252 bytes
                // (0x97 for em-dash) and bash writes those verbatim,
                // corrupting anything the script echoes into a file.
                StandardInputEncoding = new System.Text.UTF8Encoding(false),
            };
            using var proc = Process.Start(psi);
            if (proc == null) return (-1, string.Empty);
            await proc.StandardInput.WriteAsync(script);
            proc.StandardInput.Close();
            var stdout = await proc.StandardOutput.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return (proc.ExitCode, stdout);
        }

        // ────────────────────────── Configuration Backup ──────────────────────────

        private static (string user, string pass)? PromptAdminCredentials(string title, string message,
                                                                         string errorText = null,
                                                                         string prefillUser = "admin")
        {
            bool hasError = !string.IsNullOrEmpty(errorText);
            int errorOffset = hasError ? 28 : 0;
            using var form = new Form
            {
                Text = title,
                Width = 380,
                Height = 220 + errorOffset,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                StartPosition = FormStartPosition.CenterScreen,
                MinimizeBox = false,
                MaximizeBox = false,
            };
            var msg = new Label { Text = message, AutoSize = false, Width = 340, Height = 40, Top = 10, Left = 15 };
            var controls = new List<Control> { msg };
            if (hasError)
            {
                var errorLabel = new Label
                {
                    Text = errorText,
                    AutoSize = false,
                    Width = 340,
                    Height = 22,
                    Top = 52,
                    Left = 15,
                    ForeColor = Color.Firebrick,
                    Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
                };
                controls.Add(errorLabel);
            }
            var userLabel = new Label { Text = "Admin username:", Width = 120, Top = 60 + errorOffset, Left = 15 };
            var userBox = new TextBox { Width = 220, Top = 58 + errorOffset, Left = 140, Text = prefillUser };
            var passLabel = new Label { Text = "Admin password:", Width = 120, Top = 92 + errorOffset, Left = 15 };
            var passBox = new TextBox { Width = 220, Top = 90 + errorOffset, Left = 140, UseSystemPasswordChar = true };
            var okBtn = new Button { Text = "Continue", DialogResult = DialogResult.OK, Width = 90, Top = 135 + errorOffset, Left = 175 };
            var cancelBtn = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 90, Top = 135 + errorOffset, Left = 270 };
            controls.AddRange(new Control[] { userLabel, userBox, passLabel, passBox, okBtn, cancelBtn });
            form.Controls.AddRange(controls.ToArray());
            form.AcceptButton = okBtn;
            form.CancelButton = cancelBtn;

            return form.ShowDialog() == DialogResult.OK
                ? (userBox.Text, passBox.Text)
                : ((string, string)?)null;
        }

        /// Prompt for admin credentials and authenticate; re-prompt with an inline
        /// red error up to maxAttempts. Returns null if the user cancels or
        /// exhausts attempts (latter shows a final alert).
        private async Task<ConfigBackup.AdminCredentials> AuthenticateWithRetryAsync(
            string title, string message, int maxAttempts = 3)
        {
            int attempt = 0;
            string lastUser = "admin";
            string errorText = null;
            while (attempt < maxAttempts)
            {
                var creds = PromptAdminCredentials(title, message, errorText, lastUser);
                if (creds is null) return null;   // user cancelled
                lastUser = creds.Value.user;
                try
                {
                    return await ConfigBackup.AuthenticateAsAdminAsync(
                        creds.Value.user, creds.Value.pass);
                }
                catch (Exception ex)
                {
                    attempt++;
                    errorText = ex.Message;
                    if (attempt >= maxAttempts) break;
                }
            }
            MessageBox.Show(
                "Please verify your admin credentials and try again later.",
                "Too many failed attempts",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return null;
        }

        private async Task ExportConfigurationAsync()
        {
            var authed = await AuthenticateWithRetryAsync(
                "Export Configuration",
                "Enter admin credentials. They authorize the export and will also encrypt the backup file.");
            if (authed == null) return;

            try
            {
                using var dlg = new SaveFileDialog
                {
                    Filter = "FalconPulsar Config (*.fpconfig)|*.fpconfig",
                    FileName = $"falconpulsar-config-{DateTime.Now:yyyyMMdd-HHmmss}.fpconfig",
                    Title = "Save Configuration Backup",
                };
                if (dlg.ShowDialog() != DialogResult.OK) return;

                await ConfigBackup.ExportAsync(dlg.FileName, authed);

                MessageBox.Show(
                    $"Saved to {dlg.FileName}\n\nKeep this file private — it contains your configuration, encrypted with your admin credentials.",
                    "Export complete",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Configuration backup error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task ImportConfigurationAsync()
        {
            using var dlg = new OpenFileDialog
            {
                Filter = "FalconPulsar Config (*.fpconfig)|*.fpconfig",
                Title = "Choose Configuration Backup",
            };
            if (dlg.ShowDialog() != DialogResult.OK) return;

            var confirm = MessageBox.Show(
                "This will replace your current users, datasources, assets, and AI Capabilities configuration with those from the backup file. Your time-series data is unaffected.\n\nContinue?",
                "Replace current configuration?",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (confirm != DialogResult.OK) return;

            var authed = await AuthenticateWithRetryAsync(
                "Import Configuration",
                "Enter the admin credentials used when this backup was exported. They're required to decrypt the file and apply the changes.");
            if (authed == null) return;

            try
            {
                await ConfigBackup.ImportAsync(dlg.FileName, authed);

                int failed = ConfigBackup.LastImportErrorCount;
                if (failed > 0)
                {
                    MessageBox.Show(
                        $"Some items were rejected by the server ({failed}) — for example a datasource or mapping — so those series may have no source. Your time-series data is intact. Check the Core logs (docker logs falconpulsar-core), then Restart Stack.",
                        "Import completed with problems",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                else
                {
                    MessageBox.Show(
                        "Restart the stack (Restart Stack) for all changes to take effect.",
                        "Import complete",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Configuration backup error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Draws a filled square icon — used for Stop because Segoe MDL2 Assets
        // doesn't ship a clean filled-square glyph.
        private static Image CreateSquareIcon(Color color)
        {
            var bmp = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bmp))
            using (var brush = new SolidBrush(color))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.FillRectangle(brush, new Rectangle(4, 4, 8, 8));
            }
            return bmp;
        }

        // Renders a Segoe MDL2 Assets glyph into a 16x16 bitmap so it can be
        // used as a ToolStripMenuItem.Image. Segoe MDL2 Assets ships with
        // Windows 10+, so no font shipping is required.
        private static Image CreateGlyphIcon(string glyph, Color color)
        {
            var bmp = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bmp))
            using (var font = new Font("Segoe MDL2 Assets", 11f, FontStyle.Regular, GraphicsUnit.Pixel))
            using (var brush = new SolidBrush(color))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                var sz = g.MeasureString(glyph, font);
                var x = (16 - sz.Width) / 2f;
                var y = (16 - sz.Height) / 2f;
                g.DrawString(glyph, font, brush, x, y);
            }
            return bmp;
        }

        public void Dispose()
        {
            _pollTimer?.Dispose();
            _updateInitialTimer?.Dispose();
            _updateDailyTimer?.Dispose();
            _trayIcon?.Dispose();
            _http?.Dispose();
        }
    }
}
