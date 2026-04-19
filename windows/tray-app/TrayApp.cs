using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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

        private ToolStripMenuItem _coreItem;
        private ToolStripMenuItem _uiItem;
        private ToolStripMenuItem _gatewayItem;
        private ToolStripMenuItem _apiItem;
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

        private string ReadDistroName()
        {
            // Try config file first (written by installer)
            var configPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "FalconPulsar", "tray-config.txt");
            if (File.Exists(configPath))
            {
                var distro = File.ReadAllText(configPath).Trim();
                if (!string.IsNullOrEmpty(distro)) return distro;
            }

            // Try sentinel file
            var sentinel = Path.Combine(Path.GetTempPath(), "falconpulsar-distro.txt");
            if (File.Exists(sentinel))
            {
                var distro = File.ReadAllText(sentinel).Trim();
                if (!string.IsNullOrEmpty(distro)) return distro;
            }

            return "Ubuntu-24.04";
        }

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

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();

            // Header
            var header = new ToolStripMenuItem("FalconPulsar v0.1.0")
            { Enabled = false };
            header.Font = new Font(header.Font, FontStyle.Bold);
            menu.Items.Add(header);
            menu.Items.Add(new ToolStripSeparator());

            // Status items
            _coreItem = new ToolStripMenuItem("Core: checking...");
            _uiItem = new ToolStripMenuItem("Web UI: checking...");
            _gatewayItem = new ToolStripMenuItem("AI Capabilities: checking...");
            _apiItem = new ToolStripMenuItem("REST API: checking...");
            menu.Items.Add(_coreItem);
            menu.Items.Add(_uiItem);
            menu.Items.Add(_gatewayItem);
            menu.Items.Add(_apiItem);
            menu.Items.Add(new ToolStripSeparator());

            // Actions
            var openUi = new ToolStripMenuItem("Open Web UI", null,
                (s, e) => OpenWebUI());
            openUi.Font = new Font(openUi.Font, FontStyle.Bold);
            openUi.Image = CreateGlyphIcon("\uE774", Color.FromArgb(70, 70, 70));  // Globe
            menu.Items.Add(openUi);

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
            //   Config Files → Configuration Backup → Disable/Enable AI

            // Configuration Backup submenu (export / import)
            var backupMenu = new ToolStripMenuItem("Configuration Backup");
            backupMenu.DropDownItems.Add(new ToolStripMenuItem("Export Configuration...", null,
                async (s, e) => await ExportConfigurationAsync()));
            backupMenu.DropDownItems.Add(new ToolStripMenuItem("Import Configuration...", null,
                async (s, e) => await ImportConfigurationAsync()));
            menu.Items.Add(backupMenu);

            // AI Capabilities — single toggle (after Configuration Backup,
            // matching macOS menu order)
            if (IsAIGatewayEnabled())
                menu.Items.Add(new ToolStripMenuItem("Disable AI Capabilities", null,
                    async (s, e) => await DisableAIGatewayAsync()));
            else
                menu.Items.Add(new ToolStripMenuItem("Enable AI Capabilities", null,
                    async (s, e) => await EnableAIGatewayAsync()));

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

            if (_dockerDaemonUp)
            {
                _coreRunning = await IsContainerRunning("falconpulsar-core");
                _uiRunning = await IsContainerRunning("falconpulsar-ui");
                _gatewayRunning = await IsContainerRunning("falconpulsar-ai-gateway");
                _apiHealthy = await IsApiHealthy();
            }
            else
            {
                _coreRunning = false;
                _uiRunning = false;
                _gatewayRunning = false;
                _apiHealthy = false;
            }

            // Determine overall status — exclude disabled gateway from aggregate
            var prev = _status;
            var aiEnabled = IsAIGatewayEnabled();
            if (!_dockerDaemonUp)
            {
                _status = StackStatus.Error;   // Docker Desktop / WSL docker is down
            }
            else
            {
                var allExpected = _coreRunning && _uiRunning && (!aiEnabled || _gatewayRunning);
                var anyRunning = _coreRunning || _uiRunning || (aiEnabled && _gatewayRunning);
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
            }
            else
            {
                _coreItem.Text = _coreRunning ? "Core: Running" : "Core: Stopped";
                _coreItem.Image = CreateDot(_coreRunning ? Color.Green : Color.Red);
                _uiItem.Text = _uiRunning ? "Web UI: Running" : "Web UI: Stopped";
                _uiItem.Image = CreateDot(_uiRunning ? Color.Green : Color.Red);
                if (IsAIGatewayEnabled())
                {
                    _gatewayItem.Text = _gatewayRunning ? "AI Capabilities: Running" : "AI Capabilities: Stopped";
                    _gatewayItem.Image = CreateDot(_gatewayRunning ? Color.Green : Color.Red);
                }
                else
                {
                    _gatewayItem.Text = "AI Capabilities: Disabled";
                    _gatewayItem.Image = CreateDot(Color.Gray);
                }
                _apiItem.Text = _apiHealthy ? "REST API: Healthy" : "REST API: Not responding";
                _apiItem.Image = CreateDot(_apiHealthy ? Color.Green : Color.Gray);
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
                var resp = await _http.GetAsync("http://localhost:7433/api/v1/health");
                return resp.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        private async Task RunComposeCommand(string command)
        {
            _trayIcon.Icon = CreateStatusIcon(Color.FromArgb(234, 179, 8));
            _trayIcon.Text = "FalconPulsar: Working...";
            _startItem.Enabled = false;
            _stopItem.Enabled = false;
            _restartItem.Enabled = false;

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {_distro} -- docker compose -f {_composePath} {command}",
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
            Process.Start(new ProcessStartInfo("http://localhost:8080")
            { UseShellExecute = true });
        }

        private void ViewLogs()
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "wsl.exe",
                Arguments = $"-d {_distro} -- docker compose -f {_composePath} logs -f --tail 100",
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
                Text = "Version  0.1.0",
                Font = new Font("Consolas", 10),
                ForeColor = Color.FromArgb(200, 200, 200),
                BackColor = Color.Transparent,
                AutoSize = false,
                Size = new Size(150, 26),
                TextAlign = ContentAlignment.MiddleCenter
            });

            // Component grid with checkmarks
            string[] names = { "Core Engine", "Compose", "Web UI", "AI Capabilities" };
            string[] vers = { "latest", "v2", "latest", "latest" };
            bool[] oks = { _coreRunning, true, _uiRunning, _gatewayRunning };

            int gridY = 260;
            for (int i = 0; i < 4; i++)
            {
                int col = i % 2;
                int row = i / 2;
                int cx = 45 + col * 240;
                int cy = gridY + row * 30;

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

                panel.Controls.Add(new Label
                {
                    Text = $"{names[i]}:",
                    Font = new Font("Segoe UI", 10),
                    ForeColor = Color.FromArgb(170, 170, 170),
                    BackColor = Color.Transparent,
                    AutoSize = false,
                    Size = new Size(110, 20),
                    Location = new Point(cx + 22, cy)
                });

                panel.Controls.Add(new Label
                {
                    Text = vers[i],
                    Font = new Font("Consolas", 10),
                    ForeColor = Color.FromArgb(220, 220, 220),
                    BackColor = Color.Transparent,
                    AutoSize = false,
                    Size = new Size(80, 20),
                    Location = new Point(cx + 135, cy)
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

        // ────────────────────────── AI Gateway Toggle ────────────────────────────

        private static bool IsAIGatewayEnabled()
        {
            var envPath = Path.Combine(ConfigBackup.FalconPulsarHomeDir, ".env");
            if (!File.Exists(envPath)) return true;
            foreach (var line in File.ReadLines(envPath))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("FP_AI_GATEWAY_ENABLED="))
                {
                    var val = trimmed["FP_AI_GATEWAY_ENABLED=".Length..];
                    return val is "true" or "1" or "yes";
                }
            }
            return true;
        }

        private static void SetEnvValue(string key, string value)
        {
            var dir = ConfigBackup.FalconPulsarHomeDir;
            var envPath = Path.Combine(dir, ".env");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            var lines = File.Exists(envPath)
                ? File.ReadAllLines(envPath).ToList()
                : new List<string>();
            bool found = false;
            for (int i = 0; i < lines.Count; i++)
            {
                if (lines[i].TrimStart().StartsWith(key + "="))
                {
                    lines[i] = key + "=" + value;
                    found = true;
                    break;
                }
            }
            if (!found) lines.Add(key + "=" + value);
            File.WriteAllLines(envPath, lines);
        }

        // ── Install log tee (shared with installer: %TEMP%\falconpulsar-install.log)

        private static readonly string InstallLogPath =
            Path.Combine(Path.GetTempPath(), "falconpulsar-install.log");

        private static StreamWriter InstallLogBegin(string action)
        {
            try
            {
                // Rotate at 5 MiB, keep .1 .2 .3. Best-effort.
                try
                {
                    var fi = new FileInfo(InstallLogPath);
                    if (fi.Exists && fi.Length > 5 * 1024 * 1024)
                    {
                        for (int i = 2; i >= 1; i--)
                        {
                            var src = InstallLogPath + "." + i;
                            var dst = InstallLogPath + "." + (i + 1);
                            if (File.Exists(src))
                            {
                                if (File.Exists(dst)) File.Delete(dst);
                                File.Move(src, dst);
                            }
                        }
                        File.Move(InstallLogPath, InstallLogPath + ".1");
                    }
                }
                catch { }

                var stream = new FileStream(InstallLogPath, FileMode.Append,
                    FileAccess.Write, FileShare.Read);
                var w = new StreamWriter(stream) { AutoFlush = true };
                w.Write($"\n=== {DateTime.UtcNow:O}  {action} (platform=windows-tray, pid={Environment.ProcessId}) ===\n");
                return w;
            }
            catch { return null; }
        }

        private static void InstallLogAppend(StreamWriter w, string text)
        {
            if (w == null) return;
            try { w.Write(text); } catch { }
        }

        private static void InstallLogEnd(StreamWriter w, int exitCode)
        {
            if (w == null) return;
            try
            {
                w.Write($"=== end (exit {exitCode}) ===\n");
                w.Dispose();
            }
            catch { }
        }

        // ── WSL helpers (the real stack state lives inside WSL)

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
            };
            using var proc = Process.Start(psi);
            if (proc == null) return (-1, string.Empty);
            await proc.StandardInput.WriteAsync(script);
            proc.StandardInput.Close();
            var stdout = await proc.StandardOutput.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return (proc.ExitCode, stdout);
        }

        private async Task<bool> WslGatewayTokenExistsAsync()
        {
            var (rc, _) = await RunWslBashCaptureAsync(
                $"grep -q '^FP_API_KEY=.' '{_wslHome}/.env'");
            return rc == 0;
        }

        private async Task<int> WslWriteTokenAsync(string token)
        {
            var safe = token.Replace("'", "'\"'\"'");
            var script =
                $"TOKEN='{safe}'\n" +
                $"grep -v '^FP_API_KEY=' '{_wslHome}/.env' > /tmp/fp_env.new 2>/dev/null || true\n" +
                "echo \"FP_API_KEY=$TOKEN\" >> /tmp/fp_env.new\n" +
                $"mv /tmp/fp_env.new '{_wslHome}/.env'\n";
            var (rc, _) = await RunWslBashCaptureAsync(script);
            return rc;
        }

        // ── Service token creation (mirrors fp_bootstrap_gateway_token)

        private async Task<string> CreateGatewayServiceTokenAsync(string jwt)
        {
            using var req = new HttpRequestMessage(HttpMethod.Post,
                $"{ConfigBackup.CoreBaseUrl}/api/v1/tokens");
            req.Headers.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", jwt);
            var body = JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["name"] = "ai-gateway-token",
                ["expires_days"] = 0,
                ["permissions"] = new[] { "read", "query" }
            });
            req.Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json");

            using var resp = await _http.SendAsync(req);
            var respBody = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
                throw new Exception(
                    $"Could not create AI gateway service token (HTTP {(int)resp.StatusCode}).");
            using var doc = JsonDocument.Parse(respBody);
            if (!doc.RootElement.TryGetProperty("token", out var tok) ||
                string.IsNullOrEmpty(tok.GetString()))
                throw new Exception("Service token response missing 'token' field.");
            return tok.GetString();
        }

        // ── Streaming docker-action form (used by enable/disable AI)

        private async Task RunWslStreamingActionAsync(string title, string marker,
                                                     string bashScript, string successMessage)
        {
            using var form = new Form
            {
                Text = title,
                Width = 620,
                Height = 420,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                StartPosition = FormStartPosition.CenterScreen,
                MinimizeBox = false,
                MaximizeBox = false,
                // TopMost so the streaming log stays visible — the tray app
                // lives in the notification area and doesn't own the
                // foreground, so without this the Form can be buried behind
                // whatever window the user was last interacting with.
                TopMost = true,
            };
            var output = new RichTextBox
            {
                ReadOnly = true,
                Dock = DockStyle.Top,
                Width = 600,
                Height = 330,
                BackColor = Color.FromArgb(25, 25, 25),
                ForeColor = Color.White,
                Font = new Font(FontFamily.GenericMonospace, 9),
                ScrollBars = RichTextBoxScrollBars.Vertical,
            };
            var closeBtn = new Button
            {
                Text = "Close",
                DialogResult = DialogResult.OK,
                Width = 90,
                Top = 345,
                Left = 500,
                Enabled = false,
            };
            form.Controls.Add(output);
            form.Controls.Add(closeBtn);

            var log = InstallLogBegin(marker);

            void OnLine(string line)
            {
                if (line == null) return;
                var text = line + Environment.NewLine;
                InstallLogAppend(log, text);
                if (form.IsHandleCreated)
                {
                    try
                    {
                        form.BeginInvoke(new Action(() =>
                        {
                            output.AppendText(text);
                            output.ScrollToCaret();
                        }));
                    }
                    catch { }
                }
            }

            _ = Task.Run(async () =>
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl.exe",
                    Arguments = $"-d {_distro} -- bash",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                using var proc = new Process { StartInfo = psi };
                proc.OutputDataReceived += (s, e) => OnLine(e.Data);
                proc.ErrorDataReceived += (s, e) => OnLine(e.Data);
                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                await proc.StandardInput.WriteAsync(bashScript);
                proc.StandardInput.Close();
                await proc.WaitForExitAsync();
                int code = proc.ExitCode;
                InstallLogEnd(log, code);
                if (form.IsHandleCreated)
                {
                    try
                    {
                        form.BeginInvoke(new Action(() =>
                        {
                            output.AppendText(
                                $"{Environment.NewLine}--- Done (exit {code}) ---{Environment.NewLine}");
                            output.AppendText((code == 0
                                ? successMessage
                                : "Action may have failed. Check the log above.") + Environment.NewLine);
                            closeBtn.Enabled = true;

                            // On success show a prominent confirmation dialog
                            // so the user doesn't have to read the streaming
                            // log, with a one-click shortcut to the Web UI.
                            //
                            // Two things to get the dialog actually visible:
                            //   * Pass the streaming Form as owner so the
                            //     MessageBox stacks as a child of it (modal,
                            //     always on top of its parent).
                            //   * Drop the Form's TopMost flag first — a
                            //     TopMost owner still renders the MessageBox
                            //     below it on Windows 11 in some cases.
                            //     After the user dismisses the dialog the
                            //     log Form returns to normal Z-order so it
                            //     can be alt-tabbed like any window.
                            if (code == 0)
                            {
                                form.TopMost = false;
                                var choice = MessageBox.Show(
                                    form,
                                    successMessage + Environment.NewLine + Environment.NewLine +
                                    "Open the Web UI now?",
                                    "FalconPulsar",
                                    MessageBoxButtons.YesNo,
                                    MessageBoxIcon.Information);
                                if (choice == DialogResult.Yes)
                                {
                                    try
                                    {
                                        Process.Start(new ProcessStartInfo(
                                            "http://localhost:8080")
                                        { UseShellExecute = true });
                                    }
                                    catch { }
                                }
                            }
                        }));
                    }
                    catch { }
                }
            });

            form.ShowDialog();
            await PollHealth();
            _trayIcon.ContextMenuStrip = BuildMenu();
        }

        private async Task EnableAIGatewayAsync()
        {
            // Core must be running so we can authenticate against its REST API.
            if (!_coreRunning)
            {
                MessageBox.Show(
                    "FalconPulsar Core must be running before AI Capabilities can be enabled. Start the stack first, then try again.",
                    "Core service not running",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Admin authentication gate — every enable operation requires admin
            // credentials, matching the uninstall flow.
            var authed = await AuthenticateWithRetryAsync(
                "Enable AI Capabilities",
                "Enter admin credentials to authorize enabling AI Capabilities.");
            if (authed == null) return;   // cancelled or exhausted retries

            // First-time setup only: create the service token now that we have
            // an authenticated admin JWT in hand.
            if (!await WslGatewayTokenExistsAsync())
            {
                try
                {
                    var token = await CreateGatewayServiceTokenAsync(authed.Token);
                    var rc = await WslWriteTokenAsync(token);
                    if (rc != 0)
                        throw new Exception($"Failed to write FP_API_KEY to WSL {_wslHome}/.env");
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.Message, "Token setup failed",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
            }

            // Mirror the flag to the Windows side so the tray/fp.exe can read it.
            SetEnvValue("FP_AI_GATEWAY_ENABLED", "true");

            // Target the ai-gateway service explicitly so core/ui are never touched.
            var script =
                "export BUILDKIT_PROGRESS=plain\n" +
                "export DOCKER_CLI_HINTS=false\n" +
                $"cd '{_wslHome}' || exit 1\n" +
                "if [ ! -f gateway.yaml ]; then\n" +
                "  cat > gateway.yaml <<'EOF'\n" +
                "# FalconPulsar AI Gateway — default configuration.\n" +
                "# Providers and models are managed via the Web UI.\n" +
                "server:\n  host: \"0.0.0.0\"\n  port: 7436\n" +
                "falconpulsar:\n  url: \"http://localhost:7433\"\n  timeout: 30\n" +
                "context:\n  schema_cache_ttl: 300\n  max_conversation_tokens: 100000\n" +
                "logging:\n  level: \"INFO\"\n" +
                "EOF\n" +
                "fi\n" +
                // Defensive: strip CRLF + UTF-8 BOM from gateway.yaml. The\n" +
                // heredoc above is written via a C#->stdin->bash pipeline; on\n" +
                // Windows the encoding can be translated mid-flight and a\n" +
                // stray \\r or BOM makes Python's yaml.safe_load raise a\n" +
                // ReaderError, crashing the ai-gateway container on start.\n" +
                "sed -i '1s/^\\xef\\xbb\\xbf//; s/\\r$//' gateway.yaml 2>/dev/null || true\n" +
                "echo '[enable-ai] pulling AI gateway image…'\n" +
                "docker compose --profile ai pull ai-gateway 2>&1\n" +
                "echo '[enable-ai] starting ai-gateway container…'\n" +
                "docker compose --profile ai up -d ai-gateway 2>&1\n";

            await RunWslStreamingActionAsync(
                "Enabling AI Capabilities…",
                "enable-ai",
                script,
                "AI Capabilities enabled.\r\n\r\nClose any open FalconPulsar Web UI sessions and sign in again to see the AI features, then configure LLM providers.");
        }

        private async Task DisableAIGatewayAsync()
        {
            // Core must be running so we can authenticate the admin password.
            if (!_coreRunning)
            {
                MessageBox.Show(
                    "FalconPulsar Core must be running to authorize disabling AI Capabilities. Start the stack first, then try again.",
                    "Core service not running",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Admin authentication gate — every disable operation requires
            // admin credentials, matching the uninstall flow.
            var authed = await AuthenticateWithRetryAsync(
                "Disable AI Capabilities",
                "Enter admin credentials to authorize disabling AI Capabilities.");
            if (authed == null) return;

            var result = MessageBox.Show(
                "This will stop and remove the AI gateway container, delete its data directory and gateway.yaml, clear the service token, and delete the AI gateway image (re-enabling later will re-download it).\n\n" +
                "Core and UI stay running and untouched. Your time-series data is unaffected.\n\n" +
                "Disable and Remove AI Capabilities?",
                "Disable AI Capabilities",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (result != DialogResult.OK) return;

            SetEnvValue("FP_AI_GATEWAY_ENABLED", "false");

            // Surgical: act only on the ai-gateway service and its host bind-mount
            // data dir inside WSL. Never uses `down -v` because that would also
            // stop core/ui (they have no compose profile → always-active).
            var script =
                $"cd '{_wslHome}' || exit 1\n" +
                "echo '[disable-ai] loading environment from .env…'\n" +
                "set -a\n" +
                $". '{_wslHome}/.env' 2>/dev/null || true\n" +
                "set +a\n" +
                "IMAGE_REF=\"${FP_REGISTRY:-falconpulsar}/ai-gateway:${FP_VERSION:-latest}\"\n" +
                "GATEWAY_DATA=\"${FP_GATEWAY_DATA_DIR:-${FP_DATA_DIR}/../ai-gateway-data}\"\n" +
                "echo '[disable-ai] stopping and removing ai-gateway container (core/ui untouched)…'\n" +
                "docker compose --profile ai rm -f -s -v ai-gateway 2>&1\n" +
                "if [ -n \"$GATEWAY_DATA\" ] && [ \"$GATEWAY_DATA\" != / ] && [ -d \"$GATEWAY_DATA\" ]; then\n" +
                "  echo \"[disable-ai] removing AI gateway data directory: $GATEWAY_DATA\"\n" +
                "  rm -rf \"$GATEWAY_DATA\"\n" +
                "fi\n" +
                "echo '[disable-ai] removing gateway.yaml…'\n" +
                $"rm -f '{_wslHome}/gateway.yaml'\n" +
                "echo '[disable-ai] clearing FP_API_KEY from .env…'\n" +
                $"grep -v '^FP_API_KEY=' '{_wslHome}/.env' > /tmp/fp_env.new 2>/dev/null && mv /tmp/fp_env.new '{_wslHome}/.env'\n" +
                "echo \"[disable-ai] removing AI gateway image: $IMAGE_REF\"\n" +
                "docker rmi -f \"$IMAGE_REF\" 2>&1 || true\n" +
                "echo '[disable-ai] cleanup complete. Core and UI were not touched.'\n";

            await RunWslStreamingActionAsync(
                "Disabling AI Capabilities…",
                "disable-ai",
                script,
                "AI Capabilities disabled and removed.");
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
