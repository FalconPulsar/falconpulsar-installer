import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum StackStatus {
    case unknown, running, partiallyRunning, stopped, dockerDown
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    // Strong ref to the active streaming panel. Without this the NSPanel is
    // deallocated the moment runDockerActionPanel returns (subviews hold only
    // a weak ref back to their window), which is why the window "flashes"
    // open and vanishes.
    private var activeActionPanel: NSPanel?

    private var coreRunning = false
    private var uiRunning = false
    private var gatewayRunning = false
    private var dockerDaemonUp = false
    private var apiHealthy = false
    private var status: StackStatus = .unknown

    private let composePath = "\(NSHomeDirectory())/falconpulsar/compose.yml"
    private let homeDir = "\(NSHomeDirectory())/falconpulsar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Explicitly force the item visible. macOS remembers per-bundle-ID
        // user hide/show state in the menu bar; this ensures we start shown.
        statusItem.behavior = []
        statusItem.isVisible = true
        updateIcon(.unknown)
        buildMenu()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollHealth()
        }
        pollHealth()
    }

    // MARK: - Menu

    /// Builds an NSAttributedString where `symbol` (SF Symbol) appears inline
    /// at the start, followed by the title. All menu items using this render
    /// their leading edge at column 0 (text and icon share the same column).
    private func inlineIconTitle(_ title: String, symbol: String, color: NSColor? = nil, bold: Bool = false) -> NSAttributedString {
        let attachment = NSTextAttachment()
        var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let color = color, let base = img {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            img = base.withSymbolConfiguration(cfg)
        }
        attachment.image = img
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(attachment: attachment))
        let textAttrs: [NSAttributedString.Key: Any] = bold
            ? [.font: NSFont.boldSystemFont(ofSize: 13)]
            : [:]
        out.append(NSAttributedString(string: "  \(title)", attributes: textAttrs))
        return out
    }

    private func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "FalconPulsar v0.1.0", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "FalconPulsar v0.1.0",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Core: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Web UI: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "AI Capabilities: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "REST API: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let openUI = NSMenuItem(title: "Open Web UI", action: #selector(openWebUI), keyEquivalent: "o")
        openUI.target = self
        openUI.attributedTitle = inlineIconTitle("Open Web UI", symbol: "safari", bold: true)
        menu.addItem(openUI)

        let start = NSMenuItem(title: "Start Stack", action: #selector(startStack), keyEquivalent: "")
        start.target = self
        start.attributedTitle = inlineIconTitle("Start Stack", symbol: "play.fill")
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Stack", action: #selector(stopStack), keyEquivalent: "")
        stop.target = self
        stop.attributedTitle = inlineIconTitle("Stop Stack", symbol: "stop.fill")
        menu.addItem(stop)

        let restart = NSMenuItem(title: "Restart Stack", action: #selector(restartStack), keyEquivalent: "")
        restart.target = self
        restart.attributedTitle = inlineIconTitle("Restart Stack", symbol: "arrow.clockwise")
        menu.addItem(restart)

        // "Check for updates…" — added between stack-control items and the
        // logs/folder section so it lives next to the rest of the
        // stack-management actions. Shells out to `fp update --json`
        // (check is the default mode); on detected updates pops a confirm
        // dialog and runs `fp update --apply`. The whole flow inherits
        // install.sh's upgrade fast-path (registry probe + retry +
        // healthcheck).
        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        checkUpdates.attributedTitle = inlineIconTitle("Check for Updates…", symbol: "arrow.down.circle")
        menu.addItem(checkUpdates)
        menu.addItem(.separator())

        let logs = NSMenuItem(title: "View Logs", action: #selector(viewLogs), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)

        let folder = NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let installLog = NSMenuItem(title: "Open Install Log", action: #selector(openInstallLog), keyEquivalent: "")
        installLog.target = self
        menu.addItem(installLog)

        // Config Files submenu
        let configMenu = NSMenu()
        let coreConfig = NSMenuItem(title: "Core (falconpulsar.toml)", action: #selector(editCoreConfig), keyEquivalent: "")
        coreConfig.target = self
        configMenu.addItem(coreConfig)
        let gwConfig = NSMenuItem(title: "AI Capabilities (gateway.yaml)", action: #selector(editGatewayConfig), keyEquivalent: "")
        gwConfig.target = self
        configMenu.addItem(gwConfig)
        let composeConfig = NSMenuItem(title: "Docker Compose (compose.yml)", action: #selector(editComposeConfig), keyEquivalent: "")
        composeConfig.target = self
        configMenu.addItem(composeConfig)
        configMenu.addItem(.separator())
        let openConfigDir = NSMenuItem(title: "Open Config Folder", action: #selector(openDataFolder), keyEquivalent: "")
        openConfigDir.target = self
        configMenu.addItem(openConfigDir)
        let configItem = NSMenuItem(title: "Config Files", action: nil, keyEquivalent: "")
        configItem.submenu = configMenu
        menu.addItem(configItem)

        // Configuration backup submenu (export / import)
        let backupMenu = NSMenu()
        let exportCfg = NSMenuItem(title: "Export Configuration…", action: #selector(exportConfiguration), keyEquivalent: "")
        exportCfg.target = self
        backupMenu.addItem(exportCfg)
        let importCfg = NSMenuItem(title: "Import Configuration…", action: #selector(importConfiguration), keyEquivalent: "")
        importCfg.target = self
        backupMenu.addItem(importCfg)
        let backupItem = NSMenuItem(title: "Configuration Backup", action: nil, keyEquivalent: "")
        backupItem.submenu = backupMenu
        menu.addItem(backupItem)

        // AI Capabilities — single toggle
        if isAIGatewayEnabled() {
            let aiToggle = NSMenuItem(title: "Disable AI Capabilities", action: #selector(disableAIGateway), keyEquivalent: "")
            aiToggle.target = self
            menu.addItem(aiToggle)
        } else {
            let aiToggle = NSMenuItem(title: "Enable AI Capabilities", action: #selector(enableAIGateway), keyEquivalent: "")
            aiToggle.target = self
            menu.addItem(aiToggle)
        }

        menu.addItem(.separator())

        let autoStart = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStart.target = self
        let autoStartTitle = isAutoStartEnabled() ? "✓ Start at Login" : "Start at Login"
        autoStart.title = autoStartTitle
        menu.addItem(autoStart)

        let docs = NSMenuItem(title: "Documentation", action: #selector(openDocumentation), keyEquivalent: "d")
        docs.target = self
        menu.addItem(docs)

        let requestFeature = NSMenuItem(title: "Request a Feature…", action: #selector(openRequestFeature), keyEquivalent: "")
        requestFeature.target = self
        requestFeature.attributedTitle = inlineIconTitle(
            "Request a Feature…",
            symbol: "lightbulb.fill",
            color: NSColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1.0)
        )
        menu.addItem(requestFeature)

        let refresh = NSMenuItem(title: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let about = NSMenuItem(title: "About FalconPulsar", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let uninstall = NSMenuItem(title: "Uninstall FalconPulsar...", action: #selector(uninstallFalconPulsar), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateMenu() {
        guard let menu = statusItem.menu else { return }

        let aiEnabled = isAIGatewayEnabled()

        // When Docker itself is off, collapse the 4 status rows to a single
        // actionable message. Four separate red "Stopped" lines hides the
        // real problem (Docker Desktop is not running).
        if !dockerDaemonUp {
            let titles = [
                "Docker is not running",
                "Start Docker, then click Refresh Status",
                "",
                ""
            ]
            for i in 0..<4 {
                guard let item = menu.item(at: i + 2) else { continue }
                let attr = NSMutableAttributedString()
                if i == 0 {
                    attr.append(NSAttributedString(
                        string: "● ",
                        attributes: [.foregroundColor: NSColor.systemRed,
                                     .font: NSFont.systemFont(ofSize: 14)]))
                }
                attr.append(NSAttributedString(
                    string: titles[i],
                    attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                item.attributedTitle = attr
            }
            menu.item(at: 8)?.isEnabled = false
            menu.item(at: 9)?.isEnabled = false
            menu.item(at: 10)?.isEnabled = false
            return
        }

        // Status items are at indices 2-5 (after header + separator)
        let statuses: [(Bool, String)] = [
            (coreRunning, "Core"),
            (uiRunning, "Web UI"),
            (gatewayRunning, "AI Capabilities"),
            (apiHealthy, "REST API")
        ]

        for (i, (running, name)) in statuses.enumerated() {
            let item = menu.item(at: i + 2)!

            // AI Capabilities: show "Disabled" in gray when not enabled
            if name == "AI Capabilities" && !aiEnabled {
                let attributed = NSMutableAttributedString()
                attributed.append(NSAttributedString(
                    string: "– ",
                    attributes: [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 14)]
                ))
                attributed.append(NSAttributedString(
                    string: "\(name): Disabled",
                    attributes: [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 13)]
                ))
                item.attributedTitle = attributed
                continue
            }

            let dot = running ? "●" : "○"
            let dotColor: NSColor = running ? .systemGreen : .systemRed
            let statusText = running ? (name == "REST API" ? "Healthy" : "Running") : "Stopped"

            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(
                string: "\(dot) ",
                attributes: [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: 14)]
            ))
            attributed.append(NSAttributedString(
                string: "\(name): \(statusText)",
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            ))
            item.attributedTitle = attributed
        }

        // Enable/disable Start/Stop/Restart (indices 8, 9, 10 — after separator + Open Web UI)
        menu.item(at: 8)?.isEnabled = status != .running        // Start
        menu.item(at: 9)?.isEnabled = status != .stopped         // Stop
        menu.item(at: 10)?.isEnabled = status != .stopped        // Restart
    }

    // MARK: - Status Icon

    private func updateIcon(_ newStatus: StackStatus) {
        let tooltip: String
        let dotColor: CGColor
        switch newStatus {
        case .running:
            tooltip = "FalconPulsar: Running"
            dotColor = CGColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        case .partiallyRunning:
            tooltip = "FalconPulsar: Partially running"
            dotColor = CGColor(red: 0.92, green: 0.70, blue: 0.03, alpha: 1)
        case .stopped:
            tooltip = "FalconPulsar: Stopped"
            dotColor = CGColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        case .dockerDown:
            tooltip = "FalconPulsar: Docker is not running"
            dotColor = CGColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        case .unknown:
            tooltip = "FalconPulsar: Checking…"
            dotColor = CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
        }

        guard let button = statusItem.button else { return }

        button.title = ""
        if let img = buildIcon(dotColor: dotColor) {
            button.image = img
        } else {
            button.title = "FP"
        }
        button.toolTip = tooltip
    }

    private func buildIcon(dotColor: CGColor) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let baseCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        // 2x retina canvas (36x36) so @2x displays crisp
        let pxSize = 36
        guard let ctx = CGContext(
            data: nil,
            width: pxSize,
            height: pxSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Base logo fills the whole 36x36
        ctx.interpolationQuality = .high
        ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: pxSize, height: pxSize))

        // Status dot: 12x12 at bottom-right with a 2px white halo
        let dotDiameter: CGFloat = 12
        let dotX: CGFloat = CGFloat(pxSize) - dotDiameter - 2
        let dotY: CGFloat = 2
        let haloRect = CGRect(x: dotX - 2, y: dotY - 2, width: dotDiameter + 4, height: dotDiameter + 4)
        let dotRect = CGRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: haloRect)
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: dotRect)

        guard let composed = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: composed, size: NSSize(width: 18, height: 18))
        img.isTemplate = false
        return img
    }

    private func createStatusImage(color: NSColor) -> NSImage {
        // Write the PNG to a temp file once, then load via NSImage(contentsOfFile:).
        // File-based NSImage loading has proven the most reliable path for
        // menu bar status items on modern macOS.
        let tmpPath = NSTemporaryDirectory() + "falconpulsar-menubar-icon.png"
        if !FileManager.default.fileExists(atPath: tmpPath) {
            if let data = Data(base64Encoded: LogoData.base64) {
                try? data.write(to: URL(fileURLWithPath: tmpPath))
            }
        }
        if let img = NSImage(contentsOfFile: tmpPath) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            return img
        }
        // Last-resort fallback: SF Symbol as a template image
        let fallback = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                               accessibilityDescription: "FalconPulsar") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    // MARK: - Health Polling

    private func pollHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // Check the Docker daemon itself BEFORE asking about containers.
            // If Docker Desktop / Colima / OrbStack is off, every container
            // query below returns false and we used to report "Stopped" —
            // confusing because the user might think FalconPulsar is broken
            // when the real cause is that Docker isn't running.
            self.dockerDaemonUp = self.isDockerDaemonRunning()

            if self.dockerDaemonUp {
                self.coreRunning = self.isContainerRunning("falconpulsar-core")
                self.uiRunning = self.isContainerRunning("falconpulsar-ui")
                self.gatewayRunning = self.isContainerRunning("falconpulsar-ai-gateway")
                self.apiHealthy = self.isAPIHealthy()
            } else {
                self.coreRunning = false
                self.uiRunning = false
                self.gatewayRunning = false
                self.apiHealthy = false
            }

            let prev = self.status
            let aiEnabled = self.isAIGatewayEnabled()
            if !self.dockerDaemonUp {
                self.status = .dockerDown
            } else {
                let allExpectedRunning: Bool
                if aiEnabled {
                    allExpectedRunning = self.coreRunning && self.uiRunning && self.gatewayRunning
                } else {
                    allExpectedRunning = self.coreRunning && self.uiRunning
                }
                let anyRunning = self.coreRunning || self.uiRunning || (aiEnabled && self.gatewayRunning)
                if allExpectedRunning && self.apiHealthy {
                    self.status = .running
                } else if allExpectedRunning {
                    self.status = .partiallyRunning
                } else if anyRunning {
                    self.status = .partiallyRunning
                } else {
                    self.status = .stopped
                }
            }

            DispatchQueue.main.async {
                self.updateIcon(self.status)
                self.updateMenu()

                if prev != .unknown && prev != self.status {
                    self.showNotification()
                }
            }
        }
    }

    /// Probe the Docker daemon directly. True when `docker info` succeeds,
    /// false if Docker Desktop / Colima / OrbStack is off.
    private func isDockerDaemonRunning() -> Bool {
        let output = shell("docker info --format '{{.ServerVersion}}' 2>/dev/null")
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isContainerRunning(_ name: String) -> Bool {
        let output = shell("docker ps --filter name=\(name) --filter status=running -q 2>/dev/null")
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isAPIHealthy() -> Bool {
        let output = shell("curl -sf http://localhost:7433/api/v1/health 2>/dev/null")
        return !output.isEmpty
    }

    // MARK: - Actions

    @objc func openWebUI() {
        NSWorkspace.shared.open(URL(string: "http://localhost:8080")!)
    }

    @objc func startStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell("cd \(self?.homeDir ?? "~/falconpulsar") && docker compose up -d 2>&1")
            sleep(3)
            self?.pollHealth()
        }
    }

    @objc func stopStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell("cd \(self?.homeDir ?? "~/falconpulsar") && docker compose down 2>&1")
            sleep(2)
            self?.pollHealth()
        }
    }

    @objc func restartStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.shell("cd \(self?.homeDir ?? "~/falconpulsar") && docker compose restart 2>&1")
            sleep(3)
            self?.pollHealth()
        }
    }

    /// "Check for updates…" — shells out to `fp update --json`
    /// (check is the default mode), parses the result, and either tells
    /// the operator everything is up to date, prompts them to apply
    /// detected updates, or surfaces a registry-connectivity error.
    ///
    /// Apply path opens a Terminal window running `fp update --apply` so
    /// the operator can watch streaming progress (image pulls, healthcheck
    /// waits). A silent background apply is the wrong UX for an update
    /// flow — operators want to see what's happening, especially in
    /// industrial settings where unattended restarts can disrupt
    /// processes.
    @objc func checkForUpdates() {
        let fpBin = "\(homeDir)/bin/fp"
        guard FileManager.default.fileExists(atPath: fpBin) else {
            showSimpleAlert(
                title: "fp CLI not found",
                message: "Expected \(fpBin). Re-run the installer to install the CLI, then try again."
            )
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // `fp update --json` (no `--check` — that's the default mode of
            // `fp update`; the binary only knows `--apply` and `--json`).
            let json = self.shell("\"\(fpBin)\" update --json 2>/dev/null")
            DispatchQueue.main.async {
                self.handleUpdateCheckJSON(json, fpBin: fpBin)
            }
        }
    }

    private func handleUpdateCheckJSON(_ json: String, fpBin: String) {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            showSimpleAlert(
                title: "Couldn't read update status",
                message: "fp update --json did not return parseable JSON. Run it from a terminal for details."
            )
            return
        }

        let registry = parsed["registry"] as? String ?? "(unknown)"
        let tag = parsed["tag"] as? String ?? "(unknown)"
        let anyUpdate = parsed["any_update_available"] as? Bool ?? false
        let anyError = parsed["any_probe_failed"] as? Bool ?? false
        let components = parsed["components"] as? [[String: Any]] ?? []

        // Build a per-component summary line for the alert body.
        var lines: [String] = ["Registry: \(registry)   Tag: \(tag)", ""]
        for comp in components {
            let name = (comp["name"] as? String) ?? "?"
            let errorKind = comp["error_kind"] as? String ?? ""
            let updateAvail = comp["update_available"] as? Bool ?? false
            let local = comp["local_digest"] as? String ?? ""
            switch true {
            case !errorKind.isEmpty:
                lines.append("  ⚠  \(name): \(errorKind)")
            case updateAvail:
                lines.append("  ↑  \(name): update available")
            case local.isEmpty:
                lines.append("  –  \(name): container not running")
            default:
                lines.append("  ✓  \(name): up to date")
            }
        }

        if anyError {
            // Surface the categorized error to the operator. Most common
            // case in private-registry deployments: expired credentials.
            // The fp_registry_ensure_access flow inside install.sh's
            // upgrade fast-path will re-prompt for them when --apply runs.
            let alert = NSAlert()
            alert.messageText = "Registry probe failed"
            alert.informativeText = lines.joined(separator: "\n")
                + "\n\nTry running the installer again — it can re-authenticate with the registry."
            alert.addButton(withTitle: "Open Installer")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                runApplyInTerminal(fpBin: fpBin)
            }
            return
        }

        if !anyUpdate {
            let alert = NSAlert()
            alert.messageText = "All components are up to date"
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Updates available. The "auto" mode launches apply directly;
        // "manual" mode requires explicit confirmation. v1 limitation:
        // auto only fires while the tray app is open (no background
        // daemon). The 30s countdown lives in the same Terminal window
        // the apply opens.
        let mode = self.readUpdateMode()
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nUpdate mode: \(mode)."
        alert.addButton(withTitle: "Apply Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            runApplyInTerminal(fpBin: fpBin)
        }
    }

    /// Reads FP_UPDATE_MODE out of .env via `fp update mode` (no flags).
    /// Falls back to "manual" on any failure — the safe default.
    private func readUpdateMode() -> String {
        let fpBin = "\(homeDir)/bin/fp"
        let raw = shell("\"\(fpBin)\" update mode 2>/dev/null")
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (v == "auto") ? "auto" : "manual"
    }

    /// Opens Terminal.app running `fp update --apply` so the operator
    /// can see streaming progress (image pulls, healthcheck status).
    /// Same .command-script trick used by viewLogs().
    private func runApplyInTerminal(fpBin: String) {
        let scriptPath = NSTemporaryDirectory() + "falconpulsar-update.command"
        let body = """
        #!/bin/bash
        cd "\(homeDir)" || exit 1
        echo "Running: fp update --apply"
        echo
        \"\(fpBin)\" update --apply
        echo
        echo "Done. You may close this window."
        """
        try? body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: scriptPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }

    /// Lightweight NSAlert wrapper used by checkForUpdates error paths.
    private func showSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func viewLogs() {
        // Write a .command shell script; opening it launches Terminal
        // automatically via LaunchServices — no AppleScript permissions
        // required. The script runs `docker compose logs -f` in the
        // user's stack directory.
        let scriptPath = NSTemporaryDirectory() + "falconpulsar-logs.command"
        let body = """
        #!/bin/bash
        cd \"\(homeDir)\" || exit 1
        exec docker compose logs -f --tail 100
        """
        try? body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: scriptPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir))
    }

    @objc func editCoreConfig() {
        openFileInEditor("\(homeDir)/data/falconpulsar.toml")
    }

    @objc func editGatewayConfig() {
        openFileInEditor("\(homeDir)/gateway.yaml")
    }

    @objc func editComposeConfig() {
        openFileInEditor("\(homeDir)/compose.yml")
    }

    private func openFileInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "File not found"
            alert.informativeText = "The file \(path) does not exist. FalconPulsar may not be installed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func openInstallLog() {
        let logPath = "/tmp/falconpulsar-install.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    @objc func toggleAutoStart() {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.falconpulsar.menubar.plist"
        let fm = FileManager.default

        if fm.fileExists(atPath: plistPath) {
            shell("launchctl unload '\(plistPath)' 2>/dev/null")
            try? fm.removeItem(atPath: plistPath)
        } else {
            // Resolve the installed app path (/Applications takes precedence)
            let candidates = [
                "/Applications/FalconPulsar Menu Bar.app",
                "\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app",
            ]
            let appBundle = candidates.first { fm.fileExists(atPath: $0) } ?? candidates[0]
            let appBinary = "\(appBundle)/Contents/MacOS/FalconPulsarMenuBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.falconpulsar.menubar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appBinary)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? fm.createDirectory(atPath: "\(NSHomeDirectory())/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            // Do NOT `launchctl load` here — we're already running, and
            // loading would spawn a duplicate instance. launchd picks the
            // plist up automatically at next login.
        }

        // Rebuild the entire menu so the checkmark prefix updates and
        // any other state-dependent items refresh.
        buildMenu()
    }

    private func isAutoStartEnabled() -> Bool {
        return FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/Library/LaunchAgents/com.falconpulsar.menubar.plist")
    }

    @objc func openDocumentation() {
        NSWorkspace.shared.open(URL(string: "https://falconpulsar.com/docs")!)
    }

    @objc func openRequestFeature() {
        NSWorkspace.shared.open(URL(string: "https://falconpulsar.com/roadmap#request-form")!)
    }

    // MARK: - AI Gateway Toggle

    private func isAIGatewayEnabled() -> Bool {
        let envPath = "\(homeDir)/.env"
        guard let data = try? String(contentsOfFile: envPath, encoding: .utf8) else { return true }
        for line in data.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("FP_AI_GATEWAY_ENABLED=") {
                let val = trimmed.replacingOccurrences(of: "FP_AI_GATEWAY_ENABLED=", with: "")
                return val == "true" || val == "1" || val == "yes"
            }
        }
        return true
    }

    private func setEnvValue(_ key: String, _ value: String) {
        let envPath = "\(homeDir)/.env"
        guard let data = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }
        var lines = data.components(separatedBy: "\n")
        var found = false
        for i in 0..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") {
                lines[i] = "\(key)=\(value)"
                found = true
                break
            }
        }
        if !found { lines.append("\(key)=\(value)") }
        try? lines.joined(separator: "\n").write(toFile: envPath, atomically: true, encoding: .utf8)
    }

    private func removeEnvValue(_ key: String) {
        let envPath = "\(homeDir)/.env"
        guard let data = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }
        let lines = data.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=")
        }
        try? lines.joined(separator: "\n").write(toFile: envPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Install log tee (shared with installer-app: /tmp/falconpulsar-install.log)

    private static let installLogPath = "/tmp/falconpulsar-install.log"

    private func installLogBegin(action: String) -> FileHandle? {
        let fm = FileManager.default
        // Rotate at 5 MiB, keep 3 archives (.1 .2 .3).
        if let attrs = try? fm.attributesOfItem(atPath: Self.installLogPath),
           let size = attrs[.size] as? UInt64, size > 5 * 1024 * 1024 {
            for i in stride(from: 2, through: 1, by: -1) {
                let src = "\(Self.installLogPath).\(i)"
                let dst = "\(Self.installLogPath).\(i + 1)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try? fm.moveItem(atPath: src, toPath: dst)
                }
            }
            try? fm.moveItem(atPath: Self.installLogPath,
                             toPath: "\(Self.installLogPath).1")
        }
        if !fm.fileExists(atPath: Self.installLogPath) {
            // Create with 0600 — contains admin usernames + partial errors.
            fm.createFile(atPath: Self.installLogPath, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        } else {
            // Existing file might have been created by the Swift installer
            // or a shell script with a looser umask. Lock it down.
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: Self.installLogPath)
        }
        guard let fh = FileHandle(forWritingAtPath: Self.installLogPath) else { return nil }
        fh.seekToEndOfFile()
        let fmt = ISO8601DateFormatter()
        let header = "\n=== \(fmt.string(from: Date()))  \(action) (platform=macos-menubar, pid=\(getpid())) ===\n"
        fh.write(header.data(using: .utf8) ?? Data())
        return fh
    }

    private func installLogAppend(_ fh: FileHandle?, _ text: String) {
        guard let fh = fh, let data = text.data(using: .utf8) else { return }
        fh.write(data)
    }

    private func installLogEnd(_ fh: FileHandle?, exit code: Int32) {
        guard let fh = fh else { return }
        let footer = "=== end (exit \(code)) ===\n"
        fh.write(footer.data(using: .utf8) ?? Data())
        try? fh.close()
    }

    // MARK: - AI Gateway service token (mirrors fp_bootstrap_gateway_token)

    /// Creates the AI gateway service token via REST using a pre-authenticated admin JWT.
    private func createGatewayServiceToken(jwt: String) throws -> String {
        let url = URL(string: "http://localhost:7433/api/v1/tokens")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "ai-gateway-token",
            "expires_days": 0,
            "permissions": ["read", "query"]
        ])

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var err: Error?
        var status = 0
        URLSession.shared.dataTask(with: req) { d, resp, e in
            body = d; err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()

        if let err = err { throw err }
        guard (200..<300).contains(status),
              let data = body,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = j["token"] as? String, !tok.isEmpty else {
            throw NSError(domain: "FalconPulsar", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Could not create AI gateway service token (HTTP \(status))."
            ])
        }
        return tok
    }

    // MARK: - Streaming docker-action panel (used by enable/disable AI)

    private func runDockerActionPanel(title: String, marker: String,
                                      command: String, successMessage: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        // NSPanels hide on deactivate by default. Menu-bar apps run as
        // .accessory so they constantly gain/lose focus — that caused the
        // panel to flash open and vanish. Keep it visible until the user
        // explicitly closes it.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()
        // Retain the panel so ARC doesn't deallocate it when this function
        // returns (subviews only weakly reference their window).
        activeActionPanel = panel

        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 40, width: 530, height: 300))
        let logView = NSTextView(frame: scrollView.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor(white: 0.1, alpha: 1)
        logView.textColor = NSColor.white
        scrollView.documentView = logView
        scrollView.hasVerticalScroller = true
        panel.contentView?.addSubview(scrollView)

        let closeBtn = NSButton(frame: NSRect(x: 440, y: 5, width: 80, height: 30))
        closeBtn.title = "Close"
        closeBtn.bezelStyle = .rounded
        closeBtn.isEnabled = false
        closeBtn.target = panel
        closeBtn.action = #selector(NSPanel.orderOut(_:))
        panel.contentView?.addSubview(closeBtn)
        // Menu-bar apps run as .accessory, so their windows don't auto-front.
        // Activate the app and float the panel so the user actually sees progress.
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let logHandle = installLogBegin(action: marker)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            let pipe = Pipe()
            process.launchPath = "/bin/bash"
            process.arguments = ["-c", command]
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                self.installLogAppend(logHandle, line)
                DispatchQueue.main.async {
                    logView.string += line
                    logView.scrollToEndOfDocument(nil)
                }
            }

            try? process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = process.terminationStatus
            self.installLogEnd(logHandle, exit: exitCode)

            DispatchQueue.main.async {
                logView.string += "\n--- Done (exit \(exitCode)) ---\n"
                logView.string += exitCode == 0
                    ? "\(successMessage)\n"
                    : "Action may have failed. Check the log above.\n"
                closeBtn.isEnabled = true
                self.buildMenu()
                self.pollHealth()

                // On success show a prominent confirmation dialog so the user
                // doesn't have to read the streaming log to know it worked,
                // and give them a one-click path to the Web UI.
                if exitCode == 0 {
                    let alert = NSAlert()
                    alert.messageText = "FalconPulsar"
                    alert.informativeText = successMessage
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Open Web UI")
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn,
                       let url = URL(string: "http://localhost:8080") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func ensureGatewayConfig() {
        let p = "\(homeDir)/gateway.yaml"
        let fm = FileManager.default
        var isDir: ObjCBool = false

        // Remove if Docker created a directory instead of a file
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            try? fm.removeItem(atPath: p)
        }

        // Check if existing file contains the known-bad `providers: []`
        var needsWrite = !fm.fileExists(atPath: p)
        if !needsWrite, let content = try? String(contentsOfFile: p, encoding: .utf8) {
            if content.contains("providers: []") || content.contains("providers: {}") {
                needsWrite = true
            }
        }

        if needsWrite {
            // Copy the real shared/gateway.yaml from the installer if available
            let candidates = [
                "\(homeDir)/../shared/gateway.yaml",
                "/opt/falconpulsar-installer/shared/gateway.yaml",
            ]
            for src in candidates where fm.fileExists(atPath: src) {
                try? fm.removeItem(atPath: p)
                try? fm.copyItem(atPath: src, toPath: p)
                return
            }
            let cfg = """
            # FalconPulsar AI Gateway — default configuration.
            # Providers and models are managed via the Web UI.
            server:
              host: "0.0.0.0"
              port: 7436
            falconpulsar:
              url: "http://localhost:7433"
              timeout: 30
            context:
              schema_cache_ttl: 300
              max_conversation_tokens: 100000
            logging:
              level: "INFO"
            """
            try? cfg.write(toFile: p, atomically: true, encoding: .utf8)
        }
        // Defensive: sanitise CRLF + UTF-8 BOM in gateway.yaml. macOS
        // wouldn't normally produce these, but an imported config backup
        // or an edit from a Windows editor could — and Python's
        // yaml.safe_load in the ai-gateway container raises a ReaderError
        // on \r bytes, crashing the container on start.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            var bytes = [UInt8](data)
            var mutated = false
            // Strip UTF-8 BOM (EF BB BF).
            if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
                bytes.removeFirst(3)
                mutated = true
            }
            // Strip lone \r bytes (keeping \n) — CRLF becomes LF.
            let cleaned = bytes.filter { $0 != 0x0D }
            if cleaned.count != bytes.count { mutated = true }
            if mutated {
                try? Data(cleaned).write(to: URL(fileURLWithPath: p))
            }
        }
    }

    private func hasGatewayToken() -> Bool {
        let envPath = "\(homeDir)/.env"
        guard let data = try? String(contentsOfFile: envPath, encoding: .utf8) else { return false }
        for line in data.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("FP_API_KEY=") {
                return !t.replacingOccurrences(of: "FP_API_KEY=", with: "").isEmpty
            }
        }
        return false
    }

    @objc func enableAIGateway() {
        // Core must be running so we can authenticate against its REST API.
        guard coreRunning else {
            let alert = NSAlert()
            alert.messageText = "Core service not running"
            alert.informativeText = "FalconPulsar Core must be running before AI Capabilities can be enabled. Start the stack first, then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Admin authentication gate — every enable operation requires admin
        // credentials, matching the uninstall flow. Matches 3-attempt retry.
        guard let authed = authenticateWithRetry(
            title: "Enable AI Capabilities",
            message: "Enter admin credentials to authorize enabling AI Capabilities."
        ) else { return }   // user cancelled or exhausted retries

        // First-time setup only: create the service token now that we have
        // an authenticated admin JWT in hand.
        if !hasGatewayToken() {
            do {
                let apiKey = try createGatewayServiceToken(jwt: authed.token)
                setEnvValue("FP_API_KEY", apiKey)
            } catch {
                showError(error, title: "Enable AI Capabilities")
                return
            }
        }

        ensureGatewayConfig()
        setEnvValue("FP_AI_GATEWAY_ENABLED", "true")

        // Target the ai-gateway service explicitly so core/ui are never touched.
        // BUILDKIT_PROGRESS=plain forces line-buffered output over our pipe.
        //
        // The trailing wipe block removes the AI gateway image's self-seeded
        // provider/model catalog (3 providers + 6 models inserted on first
        // boot from the falconpulsar/ai-gateway repo). Without this the user
        // would land on a Models page showing 6 "Offline" entries they
        // never configured. Mirrors fp_wipe_gateway_seed_defaults in
        // shared/lib/bootstrap.sh and actions.WipeGatewaySeedDefaults in Go;
        // all three implementations must do the same SQL so post-enable
        // state is identical regardless of which surface enabled AI.
        // TODO(falconpulsar/ai-gateway): land the upstream fix and remove.
        let command = """
        export BUILDKIT_PROGRESS=plain
        export DOCKER_CLI_HINTS=false
        export PATH='/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin':"$PATH"
        cd '\(homeDir)' || exit 1
        echo '[enable-ai] pulling AI gateway image…'
        docker compose --profile ai pull ai-gateway 2>&1
        echo '[enable-ai] starting ai-gateway container…'
        docker compose --profile ai up -d ai-gateway 2>&1

        # ── Wipe self-seeded providers + models ─────────────────────────
        echo '[wipe-seed] waiting for AI Gateway to finish init…'
        deadline=$(( $(date +%s) + 90 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            if curl -fsS -o /dev/null http://127.0.0.1:7436/health 2>/dev/null; then
                break
            fi
            sleep 2
        done
        if curl -fsS -o /dev/null http://127.0.0.1:7436/health 2>/dev/null; then
            echo '[wipe-seed] removing self-seeded providers and models…'
            docker exec falconpulsar-ai-gateway sqlite3 /app/data/ai_config.db \
                'DELETE FROM model_definitions; DELETE FROM provider_configs;' \
                >/dev/null 2>&1 || echo '[wipe-seed] WARN: sqlite3 wipe failed — continuing'
            echo '[wipe-seed] restarting AI Gateway so in-memory state matches DB…'
            docker restart falconpulsar-ai-gateway >/dev/null 2>&1 || true
            deadline=$(( $(date +%s) + 60 ))
            while [ "$(date +%s)" -lt "$deadline" ]; do
                if curl -fsS -o /dev/null http://127.0.0.1:7436/health 2>/dev/null; then
                    echo '[wipe-seed] AI Gateway clean: 0 providers, 0 models'
                    break
                fi
                sleep 2
            done
        else
            echo '[wipe-seed] WARN: gateway not healthy in 90s — leaving seed defaults in place'
        fi
        """

        runDockerActionPanel(
            title: "Enabling AI Capabilities…",
            marker: "enable-ai",
            command: command,
            successMessage: "AI Capabilities enabled.\n\nClose any open FalconPulsar Web UI sessions and sign in again to see the AI features, then configure LLM providers."
        )
    }

    @objc func disableAIGateway() {
        // Core must be running so we can authenticate. If it isn't, we have
        // no way to verify the admin password — bail with a friendly notice.
        guard coreRunning else {
            let alert = NSAlert()
            alert.messageText = "Core service not running"
            alert.informativeText = "FalconPulsar Core must be running to authorize disabling AI Capabilities. Start the stack first, then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Admin authentication gate — every disable operation requires admin
        // credentials, matching the uninstall flow.
        guard authenticateWithRetry(
            title: "Disable AI Capabilities",
            message: "Enter admin credentials to authorize disabling AI Capabilities."
        ) != nil else { return }

        let alert = NSAlert()
        alert.messageText = "Disable AI Capabilities?"
        alert.informativeText = "This will stop and remove the AI gateway container, delete its data directory and gateway.yaml, clear the service token, and delete the AI gateway image (re-enabling later will re-download it). Core and UI stay running and untouched. Your time-series data is unaffected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disable and Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setEnvValue("FP_AI_GATEWAY_ENABLED", "false")
        removeEnvValue("FP_API_KEY")
        try? FileManager.default.removeItem(atPath: "\(homeDir)/gateway.yaml")

        // Surgical: act only on the ai-gateway service and its host bind-mount data dir.
        // Never uses `down -v` because that would also stop core/ui (they have no profile
        // so compose treats them as always-active).
        let command = """
        export PATH='/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin':"$PATH"
        cd '\(homeDir)' || exit 1

        echo '[disable-ai] loading environment from .env…'
        set -a
        . '\(homeDir)/.env' 2>/dev/null || true
        set +a
        IMAGE_REF="${FP_REGISTRY:-falconpulsar}/ai-gateway:${FP_VERSION:-latest}"
        GATEWAY_DATA="${FP_GATEWAY_DATA_DIR:-${FP_DATA_DIR}/../ai-gateway-data}"

        echo '[disable-ai] stopping and removing ai-gateway container (core/ui untouched)…'
        docker compose --profile ai rm -f -s -v ai-gateway 2>&1

        if [ -n "$GATEWAY_DATA" ] && [ "$GATEWAY_DATA" != "/" ] && [ -d "$GATEWAY_DATA" ]; then
          echo "[disable-ai] removing AI gateway data directory: $GATEWAY_DATA"
          rm -rf "$GATEWAY_DATA"
        fi

        echo "[disable-ai] removing AI gateway image: $IMAGE_REF"
        docker rmi -f "$IMAGE_REF" 2>&1 || true

        echo '[disable-ai] cleanup complete. Core and UI were not touched.'
        """

        runDockerActionPanel(
            title: "Disabling AI Capabilities…",
            marker: "disable-ai",
            command: command,
            successMessage: "AI Capabilities disabled and removed."
        )
    }

    // MARK: - Configuration Backup

    private func promptAdminCredentials(title: String, message: String,
                                        errorText: String? = nil,
                                        prefillUser: String = "admin")
        -> (user: String, pass: String)?
    {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = errorText == nil ? .informational : .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let hasError = errorText != nil
        let errorHeight: CGFloat = hasError ? 24 : 0
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 64 + errorHeight))
        if let errorText = errorText {
            let errorLabel = NSTextField(frame: NSRect(x: 0, y: 64, width: 300, height: 22))
            errorLabel.isEditable = false
            errorLabel.isBordered = false
            errorLabel.drawsBackground = false
            errorLabel.textColor = NSColor.systemRed
            errorLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            errorLabel.stringValue = errorText
            container.addSubview(errorLabel)
        }
        let userField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        userField.placeholderString = "Admin username"
        userField.stringValue = prefillUser
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passField.placeholderString = "Admin password"
        container.addSubview(userField)
        container.addSubview(passField)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (userField.stringValue, passField.stringValue)
    }

    /// Prompt for admin credentials and authenticate. On failure, re-prompt with
    /// an inline error (in red) up to `maxAttempts`. Returns nil if the user
    /// cancels or exhausts attempts. Exhaustion shows a final alert.
    private func authenticateWithRetry(title: String,
                                       message: String,
                                       maxAttempts: Int = 3)
        -> ConfigBackup.AdminCredentials?
    {
        var attempt = 0
        var lastUser = "admin"
        var errorText: String? = nil
        while attempt < maxAttempts {
            guard let creds = promptAdminCredentials(
                title: title,
                message: message,
                errorText: errorText,
                prefillUser: lastUser
            ) else { return nil }   // user cancelled
            lastUser = creds.user
            do {
                return try ConfigBackup.authenticateAsAdmin(
                    username: creds.user, password: creds.pass)
            } catch {
                attempt += 1
                errorText = error.localizedDescription
                if attempt >= maxAttempts { break }
            }
        }
        let final = NSAlert()
        final.messageText = "Too many failed attempts"
        final.informativeText = "Please verify your admin credentials and try again later."
        final.alertStyle = .critical
        final.runModal()
        return nil
    }

    private func showError(_ err: Error, title: String = "FalconPulsar error") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = err.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    @objc func exportConfiguration() {
        guard let authed = authenticateWithRetry(
            title: "Export Configuration",
            message: "Enter admin credentials. They authorize the export and will also encrypt the backup file."
        ) else { return }

        do {
            let panel = NSSavePanel()
            panel.title = "Save Configuration Backup"
            panel.allowedContentTypes = []
            panel.nameFieldStringValue = "falconpulsar-config-\(Self.timestampSlug()).fpconfig"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try ConfigBackup.export(to: url.path, creds: authed)

            let ok = NSAlert()
            ok.messageText = "Export complete"
            ok.informativeText = "Saved to \(url.path)\n\nKeep this file private — it contains your configuration, encrypted with your admin credentials."
            ok.addButton(withTitle: "Reveal in Finder")
            ok.addButton(withTitle: "Done")
            if ok.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showError(error, title: "Configuration backup error")
        }
    }

    @objc func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Choose Configuration Backup"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let fpconfigType = UTType(filenameExtension: "fpconfig") {
            panel.allowedContentTypes = [fpconfigType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirm = NSAlert()
        confirm.messageText = "Replace current configuration?"
        confirm.informativeText = "This will replace your current users, datasources, assets, and AI Capabilities configuration with those from the backup file. Your time-series data is unaffected."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard let authed = authenticateWithRetry(
            title: "Import Configuration",
            message: "Enter the admin credentials used when this backup was exported. They're required to decrypt the file and apply the changes."
        ) else { return }

        do {
            try ConfigBackup.importBackup(from: url.path, creds: authed)

            let ok = NSAlert()
            ok.messageText = "Import complete"
            ok.informativeText = "Restart the stack (Restart Stack) for all changes to take effect."
            ok.addButton(withTitle: "OK")
            ok.runModal()
        } catch {
            showError(error, title: "Configuration backup error")
        }
    }

    private static func timestampSlug() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    @objc func refreshStatus() {
        pollHealth()
    }

    @objc func showAbout() {
        let w: CGFloat = 540
        let h: CGFloat = 480
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        aboutWindow.title = ""
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.titleVisibility = .hidden
        aboutWindow.center()
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.backgroundColor = .clear

        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.wantsLayer = true

        // Gradient background: deep blue top → darker bottom (like Docker)
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.colors = [
            NSColor(red: 0.06, green: 0.15, blue: 0.30, alpha: 1).cgColor,
            NSColor(red: 0.03, green: 0.07, blue: 0.14, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        view.layer?.addSublayer(gradient)

        // ── Hero area: large logo ──
        if let logo = LogoData.image {
            let size: CGFloat = 160
            let imgView = NSImageView(frame: NSRect(x: (w - size) / 2, y: h - size - 30, width: size, height: size))
            imgView.image = logo
            imgView.imageScaling = .scaleProportionallyUpOrDown
            view.addSubview(imgView)
        }

        // ── Title ──
        let title = NSTextField(labelWithString: "FalconPulsar")
        title.frame = NSRect(x: 0, y: h - 225, width: w, height: 36)
        title.alignment = .center
        title.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        view.addSubview(title)

        // ── Version pill ──
        let verBg = NSView(frame: NSRect(x: (w - 150) / 2, y: h - 260, width: 150, height: 26))
        verBg.wantsLayer = true
        verBg.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        verBg.layer?.cornerRadius = 13
        view.addSubview(verBg)

        let verLabel = NSTextField(labelWithString: "Version  0.1.0")
        verLabel.frame = NSRect(x: 0, y: h - 260, width: w, height: 26)
        verLabel.alignment = .center
        verLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        verLabel.textColor = NSColor(white: 0.8, alpha: 1)
        view.addSubview(verLabel)

        // ── Component grid with checkmarks ──
        let coreVer = getContainerVersion("falconpulsar-core")
        let uiVer = getContainerVersion("falconpulsar-ui")
        let gwVer = getContainerVersion("falconpulsar-ai-gateway")

        let components: [(String, String, Bool)] = [
            ("Core Engine", coreVer, coreRunning),
            ("Compose", "v2", true),
            ("Web UI", uiVer, uiRunning),
            ("AI Capabilities", gwVer, gatewayRunning)
        ]

        let gridY = h - 310
        let colW: CGFloat = 230
        let leftX: CGFloat = 45

        for (i, (name, ver, ok)) in components.enumerated() {
            let col = CGFloat(i % 2)
            let row = CGFloat(i / 2)
            let cx = leftX + col * colW
            let cy = gridY - row * 32

            let check = NSTextField(labelWithString: ok ? "✓" : "✗")
            check.frame = NSRect(x: cx, y: cy, width: 20, height: 18)
            check.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            check.textColor = ok ? NSColor.systemGreen : NSColor.systemRed
            view.addSubview(check)

            let nameLabel = NSTextField(labelWithString: name + ":")
            nameLabel.frame = NSRect(x: cx + 22, y: cy, width: 110, height: 18)
            nameLabel.font = NSFont.systemFont(ofSize: 12)
            nameLabel.textColor = NSColor(white: 0.65, alpha: 1)
            view.addSubview(nameLabel)

            let verText = NSTextField(labelWithString: ver)
            verText.frame = NSRect(x: cx + 130, y: cy, width: 90, height: 18)
            verText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            verText.textColor = NSColor(white: 0.85, alpha: 1)
            view.addSubview(verText)
        }

        // ── Links ──
        let linksY = gridY - 85
        let linkData: [(String, String)] = [
            ("Documentation", "https://falconpulsar.com/docs"),
            ("Release Notes", "https://github.com/FalconPulsar/falconpulsar-installer/releases"),
            ("License", "https://github.com/FalconPulsar/falconpulsar-installer/blob/main/LICENSE")
        ]
        let linkW: CGFloat = 140
        let totalLinksW = linkW * CGFloat(linkData.count)
        let linksStartX = (w - totalLinksW) / 2

        for (i, (title, _)) in linkData.enumerated() {
            let lx = linksStartX + CGFloat(i) * linkW
            let link = NSButton(frame: NSRect(x: lx, y: linksY, width: linkW, height: 18))
            link.title = title
            link.bezelStyle = .inline
            link.isBordered = false
            link.font = NSFont.systemFont(ofSize: 11)
            link.contentTintColor = NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
            link.target = self
            link.tag = i
            link.action = #selector(aboutLinkClicked(_:))
            view.addSubview(link)
        }

        // ── Copyright ──
        let copyY = linksY - 35
        let copyright = NSTextField(labelWithString: "Copyright (c) 2026 FalconPulsar Contributors. All rights reserved.")
        copyright.frame = NSRect(x: 0, y: copyY, width: w, height: 14)
        copyright.alignment = .center
        copyright.font = NSFont.systemFont(ofSize: 10)
        copyright.textColor = NSColor(white: 0.4, alpha: 1)
        view.addSubview(copyright)

        let tagline = NSTextField(labelWithString: "Self-host in 3 minutes. Your infrastructure, your data.")
        tagline.frame = NSRect(x: 0, y: copyY - 16, width: w, height: 14)
        tagline.alignment = .center
        tagline.font = NSFont.systemFont(ofSize: 10)
        tagline.textColor = NSColor(white: 0.35, alpha: 1)
        view.addSubview(tagline)

        aboutWindow.contentView = view
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let aboutLinks = [
        "https://falconpulsar.com/docs",
        "https://github.com/FalconPulsar/falconpulsar-installer/releases",
        "https://github.com/FalconPulsar/falconpulsar-installer/blob/main/LICENSE"
    ]

    @objc func aboutLinkClicked(_ sender: NSButton) {
        if sender.tag < aboutLinks.count {
            NSWorkspace.shared.open(URL(string: aboutLinks[sender.tag])!)
        }
    }

    private func getContainerVersion(_ name: String) -> String {
        let output = shell("docker inspect --format '{{.Config.Image}}' \(name) 2>/dev/null")
        let image = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if image.isEmpty { return "n/a" }
        if let tag = image.split(separator: ":").last {
            return String(tag)
        }
        return "latest"
    }

    @objc func uninstallFalconPulsar() {
        let alert = NSAlert()
        alert.messageText = "Uninstall FalconPulsar"
        alert.informativeText = """
        What would you like to remove?

        "Remove Everything" will delete containers, images, database, \
        configuration, and the menu bar app. This cannot be undone.

        "Keep Data" will remove the application but preserve your \
        database. You can reinstall later and your data will be preserved.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Data")
        alert.addButton(withTitle: "Remove Everything")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        let wantsPurge: Bool
        switch response {
        case .alertFirstButtonReturn:
            wantsPurge = false   // keep data
        case .alertSecondButtonReturn:
            // Remove everything — extra destructive confirmation.
            let confirm = NSAlert()
            confirm.messageText = "Are you sure?"
            confirm.informativeText = "This will permanently delete your FalconPulsar database and all data. This cannot be undone."
            confirm.alertStyle = .critical
            confirm.addButton(withTitle: "Delete Everything")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            wantsPurge = true
        default:
            return
        }

        // Admin authentication gate — require admin credentials before any
        // destructive uninstall action, matching the bash uninstall.sh. If
        // Core is not running, fall back to an explicit YES-word confirmation
        // (we can't verify credentials without Core).
        if coreRunning {
            guard authenticateWithRetry(
                title: "Uninstall FalconPulsar",
                message: "Enter admin credentials to authorize uninstallation. This prevents accidental removal of the stack."
            ) != nil else { return }   // cancelled or exhausted retries
        } else {
            let warn = NSAlert()
            warn.messageText = "Core is not running"
            warn.informativeText = "FalconPulsar Core is not running, so the admin password cannot be verified. To authorize this uninstall anyway, type exactly YES (uppercase):"
            warn.alertStyle = .warning
            warn.addButton(withTitle: "Continue")
            warn.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.placeholderString = "Type YES"
            warn.accessoryView = field

            guard warn.runModal() == .alertFirstButtonReturn, field.stringValue == "YES" else {
                return
            }
        }

        runUninstall(purge: wantsPurge)
    }

    private func runUninstall(purge: Bool) {
        pollTimer?.invalidate()
        updateIcon(.unknown)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let purgeFlag = purge ? "--purge" : "--keep"

            // Try uninstall.sh in the stack directory first
            let uninstallPaths = [
                "\(NSHomeDirectory())/falconpulsar/uninstall.sh",
                "/tmp/falconpulsar-installer/macos/uninstall.sh"
            ]

            var script: String?
            for p in uninstallPaths {
                if FileManager.default.fileExists(atPath: p) {
                    script = p
                    break
                }
            }

            if let scriptPath = script {
                // Pass --force: the menu bar already authenticated the admin
                // in Swift (authenticateWithRetry or YES-bypass), so the bash
                // script should not try to prompt for credentials again via
                // /dev/tty (which isn't attached in a GUI-launched shell and
                // would just fail + exit without cleanup).
                self?.shell("bash '\(scriptPath)' \(purgeFlag) --yes --force 2>&1")
            } else {
                // Inline uninstall if script not found. On purge, use
                // `compose down --volumes` and prune any orphan volumes +
                // images so NOTHING is left behind.
                let composeDown = purge
                    ? "cd ~/falconpulsar 2>/dev/null && docker compose --profile ai down --remove-orphans --volumes 2>/dev/null || true"
                    : "cd ~/falconpulsar 2>/dev/null && docker compose --profile ai down --remove-orphans 2>/dev/null || true"
                let removeImages = """
                    IMAGES="$(cd ~/falconpulsar 2>/dev/null && docker compose config --images 2>/dev/null | sort -u)"
                    if [ -n "$IMAGES" ]; then echo "$IMAGES" | xargs docker rmi -f 2>/dev/null || true; fi
                    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^falconpulsar/' | xargs -r docker rmi -f 2>/dev/null || true
                    """
                let pruneVolumes = purge
                    ? "docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar' | xargs -r docker volume rm -f 2>/dev/null || true"
                    : ""
                let removeHome = purge
                    ? "rm -rf ~/falconpulsar"
                    : "rm -f ~/falconpulsar/compose.yml ~/falconpulsar/.env"
                self?.shell("""
                    \(composeDown)
                    \(removeImages)
                    \(pruneVolumes)
                    \(removeHome)
                    rm -rf /Applications/FalconPulsar\\ Menu\\ Bar.app 2>/dev/null || true
                    rm -rf ~/Applications/FalconPulsar\\ Menu\\ Bar.app 2>/dev/null || true
                    launchctl bootout gui/$(id -u)/com.falconpulsar.menubar 2>/dev/null || true
                    launchctl unload ~/Library/LaunchAgents/com.falconpulsar.menubar.plist 2>/dev/null || true
                    rm -f ~/Library/LaunchAgents/com.falconpulsar.menubar.plist 2>/dev/null || true
                    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/FalconPulsar\\ Menu\\ Bar.app 2>/dev/null || true
                    """)
            }

            DispatchQueue.main.async {
                let notification = NSAlert()
                notification.messageText = "Uninstall Complete"
                if purge {
                    notification.informativeText = "FalconPulsar has been completely removed."
                } else {
                    notification.informativeText = "FalconPulsar has been removed. Your database is preserved at ~/falconpulsar/data"
                }
                notification.alertStyle = .informational
                notification.addButton(withTitle: "OK")
                notification.runModal()

                // Quit the menu bar app
                self?.pollTimer?.invalidate()
                self?.statusItem.isVisible = false
                NSApp.terminate(nil)
            }
        }
    }

    @objc func quitApp() {
        pollTimer?.invalidate()
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    private func showNotification() {
        let content = UNMutableNotificationContent()
        content.title = "FalconPulsar"
        switch status {
        case .running:
            content.body = "All containers are running."
        case .stopped:
            content.body = "All containers have stopped."
        case .partiallyRunning:
            content.body = "Some containers are not running."
        default: return
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Shell

    @discardableResult
    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let pathExport = "export PATH=\"/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:$PATH\""
        process.arguments = ["-c", "\(pathExport); \(command)"]
        process.launchPath = "/bin/bash"
        process.launch()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
