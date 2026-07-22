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

        private ToolStripMenuItem _coreItem;
        private ToolStripMenuItem _uiItem;
        private ToolStripMenuItem _gatewayItem;
        private ToolStripMenuItem _apiItem;
        private ToolStripMenuItem _engineItem;
        private ToolStripMenuItem _openEngineItem;
        private ToolStripMenuItem _startItem;
        private ToolStripMenuItem _stopItem;
        private ToolStripMenuItem _restartItem;
        private ToolStripMenuItem _autoStartItem;

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

        // Optional AI Engine service (compose profile "engine"). The
        // installer writes FP_AI_ENGINE_ENABLED=true into .env when the
        // user opts in; absent/false on most installs. Trim + case-
        // insensitive so a hand-edited "True" still counts.
        private bool EngineEnabled =>
            string.Equals(EnvValue("FP_AI_ENGINE_ENABLED")?.Trim(), "true",
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

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();

            // Header — same assembly-version source as the About panel.
            var header = new ToolStripMenuItem($"FalconPulsar v{AssemblyVersion}")
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
            menu.Items.Add(_coreItem);
            menu.Items.Add(_uiItem);
            menu.Items.Add(_gatewayItem);
            menu.Items.Add(_apiItem);
            menu.Items.Add(_engineItem);
            menu.Items.Add(new ToolStripSeparator());

            // Actions
            var openUi = new ToolStripMenuItem("Open Web UI", null,
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

            if (_dockerDaemonUp)
            {
                _coreRunning = await IsContainerRunning("falconpulsar-core");
                _uiRunning = await IsContainerRunning("falconpulsar-ui");
                _gatewayRunning = await IsContainerRunning("falconpulsar-ai-gateway");
                _engineRunning = _engineEnabled && await IsContainerRunning("falconpulsar-ai-engine");
                _apiHealthy = await IsApiHealthy();
            }
            else
            {
                _coreRunning = false;
                _uiRunning = false;
                _gatewayRunning = false;
                _engineRunning = false;
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
                    && (!_engineEnabled || _engineRunning);
                var anyRunning = _coreRunning || _uiRunning || _gatewayRunning
                    || _engineRunning;
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
            _trayIcon.Icon = CreateStatusIcon(color);
            _trayIcon.Text = tooltip;

            // AI Engine row + "Open AI Engine" only show on engine-enabled
            // installs; re-toggled every pass so .env edits apply without
            // restarting the tray.
            _engineItem.Visible = _engineEnabled;
            _openEngineItem.Visible = _engineEnabled;

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
                var psi = new ProcessStartInfo
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
                using var proc = Process.Start(psi)!;
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

            // Build the per-component summary line for the dialog body.
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
            string body = string.Join("\n", lines);

            if (summary.AnyError)
            {
                var res = MessageBox.Show(
                    body + "\n\nRegistry probe failed (often: expired credentials).\n" +
                           "The installer can re-authenticate. Run it now?",
                    "Registry probe failed",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (res == DialogResult.OK)
                    OpenApplyTerminal();
                return;
            }

            if (!summary.Any)
            {
                MessageBox.Show(body, "All components are up to date",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Updates available. Prompt to apply. (v1: same prompt regardless
            // of FP_UPDATE_MODE because auto-mode in v1 only fires when the
            // tray app is open, and showing a confirmation with a 30s
            // countdown isn't worth the extra UI complexity for this commit.
            // The user explicitly opens this menu — that's a manual click.)
            var applyRes = MessageBox.Show(
                body + "\n\nApply updates now?",
                "Update available",
                MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (applyRes == DialogResult.Yes)
                OpenApplyTerminal();
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
                Components = new List<ComponentSummary>()
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
            return summary;
        }

        private class UpdateCheckSummary
        {
            public string Registry { get; set; } = "";
            public string Tag { get; set; } = "";
            public bool Any { get; set; }
            public bool AnyError { get; set; }
            public List<ComponentSummary> Components { get; set; } = new();
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

        // Profile flags for every compose invocation. --profile ai: legacy
        // compose compat (pre-mandatory-gateway installs put ai-gateway
        // behind a profile); no-op on current stacks. --profile engine is
        // added when FP_AI_ENGINE_ENABLED=true: a --profile flag on the CLI
        // OVERRIDES COMPOSE_PROFILES from .env, so without it Start/Stop/
        // Restart/Logs would silently skip the AI Engine on engine-enabled
        // installs.
        private string ComposeProfileArgs =>
            EngineEnabled ? "--profile ai --profile engine" : "--profile ai";

        private async Task RunComposeCommand(string command)
        {
            _trayIcon.Icon = CreateStatusIcon(Color.FromArgb(234, 179, 8));
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

        private void OpenWebUI()
        {
            Process.Start(new ProcessStartInfo($"http://localhost:{UiPort}")
            { UseShellExecute = true });
        }

        private void OpenAiEngine()
        {
            Process.Start(new ProcessStartInfo($"http://localhost:{EnginePort}")
            { UseShellExecute = true });
        }

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

        private Icon CreateStatusIcon(Color statusColor)
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
                ClientSize = new Size(540, 480),
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
            var verPanel = new Panel
            {
                Size = new Size(150, 26),
                Location = new Point(195, 215),
                BackColor = Color.FromArgb(30, 255, 255, 255)
            };
            verPanel.Paint += (s, e) =>
            {
                e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using var brush = new SolidBrush(Color.FromArgb(25, 255, 255, 255));
                e.Graphics.FillRectangle(brush, 0, 0, 150, 26);
            };
            panel.Controls.Add(verPanel);
            verPanel.Controls.Add(new Label
            {
                Text = $"Installer  v{AssemblyVersion}",
                Font = new Font("Consolas", 10),
                ForeColor = Color.FromArgb(200, 200, 200),
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(150, 26),
                TextAlign = ContentAlignment.MiddleCenter
            });

            // Component grid with checkmarks. Each component shows its real
            // version (from OCI labels via docker inspect) plus a 7-char
            // build-identifier suffix so support requests pin the exact
            // build. Compose row reads the real engine version from
            // `docker compose version --short` instead of the static "v2".
            var coreInfo = GetContainerInfo("falconpulsar-core");
            var uiInfo   = GetContainerInfo("falconpulsar-ui");
            var gwInfo   = GetContainerInfo("falconpulsar-ai-gateway");
            var composeVer = GetComposeVersion();

            string[] names = { "Core Engine", "Compose", "Web UI", "AI Capabilities" };
            string[] vers  = { coreInfo.DisplayString, composeVer, uiInfo.DisplayString, gwInfo.DisplayString };
            bool[] oks     = { _coreRunning, true, _uiRunning, _gatewayRunning };

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
            for (int i = 0; i < 4; i++)
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
            int linksY = 340;
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
                Location = new Point(0, 390),
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
                Location = new Point(0, 410),
                TextAlign = ContentAlignment.MiddleCenter
            });

            aboutForm.ShowDialog();
        }

        private void UninstallFalconPulsar()
        {
            // Find the Inno Setup uninstaller
            var uninstExe = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "FalconPulsar", "unins000.exe");

            if (File.Exists(uninstExe))
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

                MessageBox.Show(
                    "Restart the stack (Restart Stack) for all changes to take effect.",
                    "Import complete",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
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
            _trayIcon?.Dispose();
            _http?.Dispose();
        }
    }
}
