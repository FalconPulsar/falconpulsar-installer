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

        public TrayApp()
        {
            _distro = ReadDistroName();
            _composePath = "/home/falconpulsar/compose.yml";

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

            // AI Capabilities — single toggle
            if (IsAIGatewayEnabled())
                menu.Items.Add(new ToolStripMenuItem("Disable AI Capabilities", null,
                    (s, e) => DisableAIGateway()));
            else
                menu.Items.Add(new ToolStripMenuItem("Enable AI Capabilities", null,
                    async (s, e) => await EnableAIGatewayAsync()));

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
            _coreRunning = await IsContainerRunning("falconpulsar-core");
            _uiRunning = await IsContainerRunning("falconpulsar-ui");
            _gatewayRunning = await IsContainerRunning("falconpulsar-ai-gateway");
            _apiHealthy = await IsApiHealthy();

            // Determine overall status — exclude disabled gateway from aggregate
            var prev = _status;
            var aiEnabled = IsAIGatewayEnabled();
            var allExpected = _coreRunning && _uiRunning && (!aiEnabled || _gatewayRunning);
            var anyRunning = _coreRunning || _uiRunning || (aiEnabled && _gatewayRunning);
            if (allExpected && _apiHealthy)
                _status = StackStatus.Running;
            else if (anyRunning)
                _status = StackStatus.PartiallyRunning;
            else
                _status = StackStatus.Stopped;

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
                default:
                    color = Color.Gray;
                    tooltip = "FalconPulsar: Checking...";
                    break;
            }
            _trayIcon.Icon = CreateStatusIcon(color);
            _trayIcon.Text = tooltip;

            // Update menu items
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

            // Enable/disable actions based on state
            _startItem.Enabled = _status != StackStatus.Running;
            _stopItem.Enabled = _status != StackStatus.Stopped;
            _restartItem.Enabled = _status != StackStatus.Stopped;
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
                    Arguments = $"-d {_distro} -u falconpulsar -- docker compose -f {_composePath} {command}",
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
                Arguments = $"-d {_distro} -u falconpulsar -- docker compose -f {_composePath} logs -f --tail 100",
                UseShellExecute = true
            });
        }

        private void OpenDataFolder()
        {
            Process.Start(new ProcessStartInfo("explorer.exe",
                $@"\\wsl.localhost\{_distro}\home\falconpulsar")
            { UseShellExecute = true });
        }

        private void EditConfigFile(string filename)
        {
            // Config files are inside the WSL distro at /home/falconpulsar/
            var wslPath = $@"\\wsl.localhost\{_distro}\home\falconpulsar\{filename}";
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

        private static void EnsureGatewayConfig()
        {
            var p = Path.Combine(ConfigBackup.FalconPulsarHomeDir, "gateway.yaml");
            if (Directory.Exists(p)) Directory.Delete(p, true);
            if (!File.Exists(p))
            {
                Directory.CreateDirectory(ConfigBackup.FalconPulsarHomeDir);
                File.WriteAllText(p,
                    "# FalconPulsar AI Gateway — default configuration.\n" +
                    "# Providers and models are managed via the Web UI.\n" +
                    "server:\n  host: \"0.0.0.0\"\n  port: 7436\n" +
                    "falconpulsar:\n  url: \"http://localhost:7433\"\n  timeout: 30\n" +
                    "context:\n  schema_cache_ttl: 300\n  max_conversation_tokens: 100000\n" +
                    "logging:\n  level: \"INFO\"\n");
            }
        }

        private async Task EnableAIGatewayAsync()
        {
            EnsureGatewayConfig();
            SetEnvValue("FP_AI_GATEWAY_ENABLED", "true");
            _trayIcon.ShowBalloonTip(5000, "FalconPulsar",
                "Starting AI Capabilities… this may take a moment.", ToolTipIcon.Info);
            await RunComposeCommand("--profile ai up -d");
            _trayIcon.ContextMenuStrip = BuildMenu();
            _trayIcon.ShowBalloonTip(5000, "FalconPulsar",
                "AI Capabilities is running. Configure LLM providers in the Web UI.", ToolTipIcon.Info);
        }

        private void DisableAIGateway()
        {
            var result = MessageBox.Show(
                "Chat features will be hidden in the Web UI until re-enabled.\n\nDisable AI Capabilities?",
                "Disable AI Capabilities",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (result != DialogResult.OK) return;

            SetEnvValue("FP_AI_GATEWAY_ENABLED", "false");
            Task.Run(async () => await RunComposeCommand("stop ai-gateway"));
            _trayIcon.ContextMenuStrip = BuildMenu();
        }

        // ────────────────────────── Configuration Backup ──────────────────────────

        private static (string user, string pass)? PromptAdminCredentials(string title, string message)
        {
            using var form = new Form
            {
                Text = title,
                Width = 380,
                Height = 220,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                StartPosition = FormStartPosition.CenterScreen,
                MinimizeBox = false,
                MaximizeBox = false,
            };
            var msg = new Label { Text = message, AutoSize = false, Width = 340, Height = 40, Top = 10, Left = 15 };
            var userLabel = new Label { Text = "Admin username:", Width = 120, Top = 60, Left = 15 };
            var userBox = new TextBox { Width = 220, Top = 58, Left = 140, Text = "admin" };
            var passLabel = new Label { Text = "Admin password:", Width = 120, Top = 92, Left = 15 };
            var passBox = new TextBox { Width = 220, Top = 90, Left = 140, UseSystemPasswordChar = true };
            var okBtn = new Button { Text = "Continue", DialogResult = DialogResult.OK, Width = 90, Top = 135, Left = 175 };
            var cancelBtn = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 90, Top = 135, Left = 270 };
            form.Controls.AddRange(new Control[] { msg, userLabel, userBox, passLabel, passBox, okBtn, cancelBtn });
            form.AcceptButton = okBtn;
            form.CancelButton = cancelBtn;

            return form.ShowDialog() == DialogResult.OK
                ? (userBox.Text, passBox.Text)
                : ((string, string)?)null;
        }

        private async Task ExportConfigurationAsync()
        {
            var creds = PromptAdminCredentials(
                "Export Configuration",
                "Enter admin credentials. They authorize the export and will also encrypt the backup file.");
            if (creds is null) return;

            try
            {
                var authed = await ConfigBackup.AuthenticateAsAdminAsync(creds.Value.user, creds.Value.pass);

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

            var creds = PromptAdminCredentials(
                "Import Configuration",
                "Enter the admin credentials used when this backup was exported. They're required to decrypt the file and apply the changes.");
            if (creds is null) return;

            try
            {
                var authed = await ConfigBackup.AuthenticateAsAdminAsync(creds.Value.user, creds.Value.pass);
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
