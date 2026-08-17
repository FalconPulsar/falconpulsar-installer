// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

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

    // Automatic update CHECKING (FP_UPDATE_CHECK_AUTO in .env). Passive by
    // design: the timers only ever LOOK for updates and light up an
    // indicator — nothing is ever downloaded or applied without the
    // operator going through the normal Check-for-Updates flow.
    private var autoCheckTimer: Timer?          // repeating, once per 24h
    private var autoCheckLaunchTimer: Timer?    // one-shot, ~2 min after launch
    /// Non-nil when the last check (manual or automatic) found an update;
    /// drives the icon badge + the hidden "Update available: vX" menu line.
    private var pendingUpdateLabel: String?
    private var updateAvailableItem: NSMenuItem?
    private var autoCheckMenuItem: NSMenuItem?

    private var coreRunning = false
    private var uiRunning = false
    private var gatewayRunning = false
    private var engineRunning = false
    private var copilotRunning = false
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
        // Background update checking — only ever scheduled when
        // FP_UPDATE_CHECK_AUTO=true in .env (default OFF: no timers, zero
        // background network traffic).
        configureAutoUpdateChecks()
    }

    // MARK: - Menu

    /// Builds an NSAttributedString where `symbol` appears inline at the
    /// start, followed by the title. All menu items using this render their
    /// leading edge at column 0 (text and icon share the same column).
    ///
    /// `symbol` now names an icon in shared/icons/icons.def, NOT an SF Symbol.
    /// SF Symbols is an Apple font that cannot ship on Windows, so the Windows
    /// tray drew its menu with Segoe MDL2 Assets instead and the two menus
    /// could never agree — `brain`, `square.grid.2x2` and `safari` have no MDL2
    /// equivalent at all. Both platforms now render the same geometry from the
    /// same file, so they match by construction rather than by coincidence.
    private func inlineIconTitle(_ title: String, symbol: String, color: NSColor? = nil, bold: Bool = false) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let img = IconRenderer.render(symbol,
                                      color: color ?? .labelColor,
                                      size: 14)
        // A coloured icon is a deliberate signal (the update row), so it must
        // NOT be tinted to the menu's text colour the way the plain ones are.
        img.isTemplate = (color == nil)
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

        // Version comes from Info.plist (CFBundleShortVersionString), which
        // build-dmg.sh stamps from FP_VERSION at build time — same source
        // showAbout() uses, so the two displays can't drift.
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        // "QuickDock", not "FalconPulsar". The number is this menu-bar app's
        // own build, and calling it the product's version was a false claim:
        // the About window below can simultaneously report Core at alpha.89,
        // Web UI at alpha.157 and the AI Engine at alpha.65, so the header
        // named no component the user is running. showAbout() already labels
        // this same number "QuickDock" — the header now agrees with it.
        let headerTitle = "QuickDock v\(appVersion)"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: headerTitle,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Core: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Web UI: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "AI Capabilities: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "REST API: checking...", action: nil, keyEquivalent: ""))
        // Optional AI Engine row — hidden unless FP_AI_ENGINE_ENABLED=true
        // in .env; updateMenu() re-checks the flag on every pass.
        let engineStatus = NSMenuItem(title: "AI Engine: checking...", action: nil, keyEquivalent: "")
        engineStatus.isHidden = !engineEnabled
        menu.addItem(engineStatus)
        // Optional Command Center row — hidden unless FP_COPILOT_ENABLED=true
        // in .env; updateMenu() re-checks the flag on every pass.
        let copilotStatus = NSMenuItem(title: "Command Center: checking...", action: nil, keyEquivalent: "")
        copilotStatus.isHidden = !copilotEnabled
        menu.addItem(copilotStatus)
        menu.addItem(.separator())

        let openUI = NSMenuItem(title: "Open FalconPulsar", action: #selector(openWebUI), keyEquivalent: "o")
        openUI.target = self
        openUI.attributedTitle = inlineIconTitle("Open FalconPulsar", symbol: "globe", bold: true)
        menu.addItem(openUI)

        // Optional AI Engine UI — visibility mirrors the status row above.
        let openEngine = NSMenuItem(title: "Open AI Engine", action: #selector(openAIEngine), keyEquivalent: "e")
        openEngine.target = self
        openEngine.attributedTitle = inlineIconTitle("Open AI Engine", symbol: "agents", bold: true)
        openEngine.isHidden = !engineEnabled
        menu.addItem(openEngine)

        // Optional Command Center UI — visibility mirrors the status row above.
        let openCopilot = NSMenuItem(title: "Open Command Center", action: #selector(openCommandCenter), keyEquivalent: "")
        openCopilot.target = self
        openCopilot.attributedTitle = inlineIconTitle("Open Command Center", symbol: "grid", bold: true)
        openCopilot.isHidden = !copilotEnabled
        menu.addItem(openCopilot)

        let start = NSMenuItem(title: "Start Stack", action: #selector(startStack), keyEquivalent: "")
        start.target = self
        start.attributedTitle = inlineIconTitle("Start Stack", symbol: "play")
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Stack", action: #selector(stopStack), keyEquivalent: "")
        stop.target = self
        stop.attributedTitle = inlineIconTitle("Stop Stack", symbol: "stop")
        menu.addItem(stop)

        let restart = NSMenuItem(title: "Restart Stack", action: #selector(restartStack), keyEquivalent: "")
        restart.target = self
        restart.attributedTitle = inlineIconTitle("Restart Stack", symbol: "refresh")
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
        checkUpdates.attributedTitle = inlineIconTitle("Check for Updates…", symbol: "download")
        menu.addItem(checkUpdates)

        // Passive "Update available: vX" line — hidden until a check
        // (manual or the FP_UPDATE_CHECK_AUTO background one) finds an
        // update. Clicking it runs the normal Check-for-Updates flow;
        // it never applies anything by itself. Hidden items stay in the
        // menu's items array, so the hardcoded indices in updateMenu()
        // (all < 13, before this block) are unaffected — same trick as
        // the AI Engine rows. State is restored from pendingUpdateLabel
        // because toggleAutoStart() rebuilds the whole menu.
        let updateLine = NSMenuItem(title: "Update available", action: #selector(checkForUpdates), keyEquivalent: "")
        updateLine.target = self
        updateLine.isHidden = true
        if let label = pendingUpdateLabel {
            updateLine.title = label
            updateLine.attributedTitle = inlineIconTitle(label, symbol: "update", color: .systemBlue, bold: true)
            updateLine.isHidden = false
        }
        menu.addItem(updateLine)
        updateAvailableItem = updateLine

        // "Automatically check for updates" — checkmark mirrors
        // FP_UPDATE_CHECK_AUTO in the stack's .env (read/written via
        // envValue/setAutoUpdateCheckEnabled). Checking is read-only:
        // enabling this only schedules background LOOKS for updates
        // (once per 24h + once shortly after launch); applying an
        // update always remains an explicit user action.
        let autoCheck = NSMenuItem(title: "Automatically check for updates", action: #selector(toggleAutoUpdateCheck), keyEquivalent: "")
        autoCheck.target = self
        autoCheck.state = autoUpdateCheckEnabled ? .on : .off
        menu.addItem(autoCheck)
        autoCheckMenuItem = autoCheck
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
            symbol: "bulb",
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

        // Engine items follow FP_AI_ENGINE_ENABLED on every pass, so editing
        // .env takes effect on the next poll without an app restart. Hidden
        // items stay in the menu's items array, keeping the hardcoded
        // indices below stable.
        // Opted in, OR actually up — a running service is never hidden
        // because its .env could not be read. Mirrors TrayApp.cs.
        let engineOn = engineEnabled || engineRunning
        let copilotOn = copilotEnabled || copilotRunning
        menu.item(at: 6)?.isHidden = !engineOn     // AI Engine status row
        menu.item(at: 7)?.isHidden = !copilotOn    // Command Center status row
        menu.item(at: 10)?.isHidden = !engineOn    // Open AI Engine
        menu.item(at: 11)?.isHidden = !copilotOn   // Open Command Center

        // Auto-update-check checkmark follows .env on every pass too, so a
        // hand-edited FP_UPDATE_CHECK_AUTO takes effect without an app
        // restart — including starting/stopping the background timers when
        // the flag flipped underneath us.
        let autoOn = autoUpdateCheckEnabled
        autoCheckMenuItem?.state = autoOn ? .on : .off
        if autoOn != (autoCheckTimer != nil) {
            configureAutoUpdateChecks()
        }

        // When Docker itself is off, collapse the 5 status rows to a single
        // actionable message. Five separate red "Stopped" lines hides the
        // real problem (Docker Desktop is not running).
        if !dockerDaemonUp {
            let titles = [
                "Docker is not running",
                "Start Docker, then click Refresh Status",
                "",
                "",
                "",
                ""
            ]
            for i in 0..<6 {
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
            menu.item(at: 12)?.isEnabled = false
            menu.item(at: 13)?.isEnabled = false
            menu.item(at: 14)?.isEnabled = false
            return
        }

        // Status items are at indices 2-7 (after header + separator)
        let statuses: [(Bool, String)] = [
            (coreRunning, "Core"),
            (uiRunning, "Web UI"),
            (gatewayRunning, "AI Capabilities"),
            (apiHealthy, "REST API"),
            (engineRunning, "AI Engine"),
            (copilotRunning, "Command Center")
        ]

        for (i, (running, name)) in statuses.enumerated() {
            let item = menu.item(at: i + 2)!

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

        // Enable/disable Start/Stop/Restart (indices 12, 13, 14 — after the 6
        // status rows + separator + Open Web UI/AI Engine/Command Center)
        menu.item(at: 12)?.isEnabled = status != .running        // Start
        menu.item(at: 13)?.isEnabled = status != .stopped         // Stop
        menu.item(at: 14)?.isEnabled = status != .stopped        // Restart
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
            // No composed icon → text-only item, so the passive update
            // badge falls back to a title suffix instead of a drawn dot.
            button.title = pendingUpdateLabel == nil ? "FP" : "FP •"
        }
        button.toolTip = pendingUpdateLabel == nil ? tooltip : tooltip + " — update available"
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

        // Passive update badge: small blue dot at top-right, same halo
        // trick as the status dot. The status item is squareLength with an
        // image (title is empty), so a " •" title suffix would be clipped —
        // a drawn badge is the equivalent the icon pipeline supports.
        // Purely informational; set/cleared via pendingUpdateLabel.
        if pendingUpdateLabel != nil {
            let badgeDiameter: CGFloat = 10
            let bx: CGFloat = CGFloat(pxSize) - badgeDiameter - 2
            let by: CGFloat = CGFloat(pxSize) - badgeDiameter - 2
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: bx - 2, y: by - 2, width: badgeDiameter + 4, height: badgeDiameter + 4))
            ctx.setFillColor(CGColor(red: 0.04, green: 0.48, blue: 1.0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: bx, y: by, width: badgeDiameter, height: badgeDiameter))
        }

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

            // The optional AI Engine only participates when enabled in .env;
            // re-read the flag each pass so toggling it doesn't require an
            // app restart.
            let engineExpected = self.engineEnabled
            let copilotExpected = self.copilotEnabled

            if self.dockerDaemonUp {
                self.coreRunning = self.isContainerRunning("falconpulsar-core")
                self.uiRunning = self.isContainerRunning("falconpulsar-ui")
                self.gatewayRunning = self.isContainerRunning("falconpulsar-ai-gateway")
                // Probed REGARDLESS of the .env flag: the flag decides what
                // to SHOW, the container decides what is TRUE. Gating the
                // probe on the flag means an unreadable .env renders a
                // healthy container as a red X — the app accusing a running
                // service of being down. Mirrors TrayApp.cs on Windows.
                self.engineRunning = self.isContainerRunning("falconpulsar-ai-engine")
                self.copilotRunning = self.isContainerRunning("falconpulsar-copilot")
                self.apiHealthy = self.isAPIHealthy()
            } else {
                self.coreRunning = false
                self.uiRunning = false
                self.gatewayRunning = false
                self.engineRunning = false
                self.copilotRunning = false
                self.apiHealthy = false
            }

            let prev = self.status
            if !self.dockerDaemonUp {
                self.status = .dockerDown
            } else {
                let allExpectedRunning = self.coreRunning && self.uiRunning && self.gatewayRunning
                    && (!engineExpected || self.engineRunning)
                    && (!copilotExpected || self.copilotRunning)
                let anyRunning = self.coreRunning || self.uiRunning || self.gatewayRunning
                    || self.engineRunning || self.copilotRunning
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
        let output = shell("curl -sf http://localhost:\(restPort)/api/v1/health 2>/dev/null")
        return !output.isEmpty
    }

    // MARK: - Stack .env

    /// Reads one value out of the stack's .env. Returns nil when the file or
    /// key is missing. Last occurrence wins, matching docker compose's own
    /// env-file semantics, so a hand-appended override behaves the same here
    /// and in the stack itself.
    private func envValue(_ key: String) -> String? {
        guard let content = try? String(contentsOfFile: "\(homeDir)/.env", encoding: .utf8) else {
            return nil
        }
        var value: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            let v = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { value = v }
        }
        return value
    }

    /// Ports come from the stack's .env so port-remapped installs report
    /// health and open the Web UI correctly; the literals are only the
    /// installer defaults, used when .env is missing or doesn't set them.
    private var restPort: String { envValue("FP_REST_PORT") ?? "7433" }
    private var uiPort: String { envValue("FP_UI_PORT") ?? "80" }
    private var enginePort: String { envValue("FP_ENGINE_PORT") ?? "8085" }
    private var copilotPort: String { envValue("FP_COPILOT_PORT") ?? "8090" }

    /// AI Engine flag. NOT an opt-out any more — the engine is a standard
    /// stack service with no compose profile, and both installers force this
    /// to "true". Read it to decide what to SHOW, never to decide whether the
    /// service is real: `engineRunning` is probed from the container itself,
    /// so an unreadable .env can no longer render a healthy engine as down.
    /// Trim + case-insensitive so hand-edited "True " still counts.
    private var engineEnabled: Bool {
        (envValue("FP_AI_ENGINE_ENABLED") ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    /// Optional Command Center flag (compose profile "copilot"). Same trim +
    /// case-insensitive treatment as engineEnabled for hand-edited values.
    private var copilotEnabled: Bool {
        (envValue("FP_COPILOT_ENABLED") ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    /// Automatic update CHECKING flag. Absent or anything other than
    /// "true" means OFF — the safe default: no timers, no background
    /// network traffic. Same trim + case-insensitive treatment as
    /// engineEnabled for hand-edited values.
    private var autoUpdateCheckEnabled: Bool {
        (envValue("FP_UPDATE_CHECK_AUTO") ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    /// Writes FP_UPDATE_CHECK_AUTO=<true|false> into the stack's .env:
    /// replaces every existing FP_UPDATE_CHECK_AUTO= line in place (all of
    /// them — envValue's last-wins semantics make stray duplicates
    /// ambiguous otherwise), or appends one at the end. Every other line
    /// passes through byte-for-byte. POSIX permissions are captured before
    /// the (atomic, hence inode-replacing) write and restored after — .env
    /// carries secrets and installs may have tightened it to 600.
    private func setAutoUpdateCheckEnabled(_ enabled: Bool) {
        let envPath = "\(homeDir)/.env"
        let fm = FileManager.default
        let assignment = "FP_UPDATE_CHECK_AUTO=\(enabled ? "true" : "false")"

        // If the .env exists but can't be read (permissions, non-UTF-8
        // byte from a hand edit), ABORT — proceeding with an empty string
        // would replace the operator's entire .env with this one line.
        let existing: String
        if fm.fileExists(atPath: envPath) {
            guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else {
                NSLog("FalconPulsar: cannot read \(envPath) — auto-update-check toggle aborted")
                return
            }
            existing = content
        } else {
            existing = ""
        }
        let savedPerms = (try? fm.attributesOfItem(atPath: envPath))?[.posixPermissions] as? NSNumber

        var lines = existing.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("FP_UPDATE_CHECK_AUTO=") {
                lines[i] = assignment
                replaced = true
            }
        }
        var content = lines.joined(separator: "\n")
        if !replaced {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += assignment + "\n"
        }
        try? content.write(toFile: envPath, atomically: true, encoding: .utf8)
        if let perms = savedPerms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: envPath)
        }
    }

    // MARK: - Actions

    /// Every destination is a route in the unified shell.
    ///
    /// These used to open the surfaces on their own ports — the Engine on
    /// \(enginePort), the Command Center on \(copilotPort) — which was right
    /// when they were three separate applications. They are now embedded, and
    /// reaching one directly means arriving without the shell around it: no
    /// mode switcher, no alarm lane, no identity, and an app waiting for a
    /// handshake from a parent frame that is not there.
    ///
    /// The status rows above still probe the services on their own ports.
    /// That is a health check and belongs where the service actually lives.
    private func openShell(path: String = "") {
        guard let url = URL(string: "http://localhost:\(uiPort)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openWebUI() {
        openShell()
    }

    @objc func openAIEngine() {
        openShell(path: "/agents")
    }

    @objc func openCommandCenter() {
        openShell(path: "/workplace")
    }

    /// Compose profile flags shared by EVERY compose invocation.
    /// "--profile ai" is legacy compose compat (pre-mandatory-gateway
    /// installs gate ai-gateway behind the "ai" profile); no-op on current
    /// stacks. A --profile CLI flag OVERRIDES COMPOSE_PROFILES from .env,
    /// so when the optional AI Engine is enabled we must ALSO name its
    /// profile explicitly here — otherwise start/stop/restart/logs/uninstall
    /// silently skip the engine container.
    private func composeProfileArgs() -> [String] {
        var args = ["--profile", "ai"]
        if engineEnabled { args += ["--profile", "engine"] }
        if copilotEnabled { args += ["--profile", "copilot"] }
        return args
    }

    @objc func startStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Profile flags: see composeProfileArgs().
            let (bin, argv) = self.dockerInvocation(["compose"] + self.composeProfileArgs() + ["up", "-d"])
            _ = self.runArgs(bin, argv, cwd: self.homeDir)
            sleep(3)
            self.pollHealth()
        }
    }

    @objc func stopStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Profile flags: see composeProfileArgs().
            let (bin, argv) = self.dockerInvocation(["compose"] + self.composeProfileArgs() + ["down"])
            _ = self.runArgs(bin, argv, cwd: self.homeDir)
            sleep(2)
            self.pollHealth()
        }
    }

    @objc func restartStack() {
        updateIcon(.partiallyRunning)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Profile flags: see composeProfileArgs().
            let (bin, argv) = self.dockerInvocation(["compose"] + self.composeProfileArgs() + ["restart"])
            _ = self.runArgs(bin, argv, cwd: self.homeDir)
            sleep(3)
            self.pollHealth()
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
            let json = self.runArgs(fpBin, ["update", "--json"])
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

        // Build a per-component summary line for the alert body. The
        // components[] list may now also carry an "AI Engine" row — fp
        // includes it when the stack has the engine enabled; nothing to
        // special-case here, it renders like any other image row.
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

        // Host section (fp CLI from the JSON + our own row computed
        // client-side). host.present is false against an old fp binary
        // that predates the host_components fields — then the section is
        // omitted entirely and the dialog renders exactly as before.
        let host = parseHostStatus(parsed)
        if host.present {
            lines.append("")
            lines.append("Host components:")
            lines.append(contentsOf: host.lines)
            if host.anyUpdate {
                lines.append("")
                lines.append("Host components update via the latest installer (Upgrade).")
            }
        }

        // A manual check is also the freshest truth for the passive
        // indicator — light it up or clear it so the badge can't go stale.
        updatePassiveIndicator(anyImageUpdate: anyUpdate, host: host)

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
            if host.anyUpdate { alert.addButton(withTitle: "Download Update") }
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                runApplyInTerminal(fpBin: fpBin)
            } else if response == .alertThirdButtonReturn {
                openInstallerDownload(host)
            }
            return
        }

        if !anyUpdate {
            let alert = NSAlert()
            if host.anyUpdate {
                // Images current, but the app / fp CLI is behind. Make the
                // update action the obvious one: a primary "Download Update"
                // that fetches the RIGHT file directly, plus the two steps to
                // apply it — so the user never has to pick a file off the
                // releases page or guess how to install.
                let ver = host.latestVersion.isEmpty ? "" : "v\(host.latestVersion)"
                alert.messageText = ver.isEmpty ? "Update available" : "Update available: \(ver)"
                alert.informativeText = lines.joined(separator: "\n")
                    + "\n\nTo update this app and the fp command:"
                    + "\n  1.  Click “Download Update” — it downloads FalconPulsar-Setup.dmg."
                    + "\n  2.  Open the downloaded file, then double-click “FalconPulsar Installer”."
                    + "\n  3.  Choose Upgrade — your data and settings are preserved."
                alert.addButton(withTitle: "Download Update")   // first = default (blue)
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    openInstallerDownload(host)
                }
            } else {
                alert.messageText = "All components are up to date"
                alert.informativeText = lines.joined(separator: "\n")
                alert.addButton(withTitle: "OK")
                _ = alert.runModal()
            }
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
        if host.anyUpdate { alert.addButton(withTitle: "Open Releases…") }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Apply Now covers the IMAGE components only (fp update
            // --apply); host components always update via the installer.
            runApplyInTerminal(fpBin: fpBin)
        } else if response == .alertThirdButtonReturn {
            openInstallerReleases(host.releaseURL)
        }
    }

    /// Reads FP_UPDATE_MODE out of .env via `fp update mode` (no flags).
    /// Falls back to "manual" on any failure — the safe default.
    private func readUpdateMode() -> String {
        let fpBin = "\(homeDir)/bin/fp"
        let raw = runArgs(fpBin, ["update", "mode"])
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

    // MARK: - Host component updates

    /// Everything the update dialog / passive indicator needs from the
    /// host-component fields `fp update --json` MAY carry (host_components,
    /// host_any_update_available, host_probe_failed, installer_release_url).
    /// `present` stays false against an old fp binary that predates them —
    /// callers then omit the host section entirely instead of guessing.
    private struct HostUpdateStatus {
        var present = false
        var lines: [String] = []
        var anyUpdate = false
        /// Normalized (no leading "v") latest installer version; "" when
        /// the probe failed or the endpoint published "none".
        var latestVersion = ""
        var releaseURL = "https://github.com/FalconPulsar/falconpulsar-installer/releases"
    }

    /// Strips an optional leading "v"/"V" so "v1.2.3" and "1.2.3" compare
    /// equal — the gist endpoint publishes with the prefix, Info.plist
    /// carries it without.
    private func normalizedVersion(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("v") || t.hasPrefix("V")) ? String(t.dropFirst()) : t
    }

    /// True when `v` (already normalized) names an actual release — the
    /// endpoint publishes "none" before the first stable release, and an
    /// unreachable probe leaves it empty.
    private func isRealVersion(_ v: String) -> Bool {
        return !v.isEmpty && v.lowercased() != "none"
    }

    /// Parses the host-component section out of a decoded `fp update
    /// --json` payload and appends OUR OWN row: fp only knows about the
    /// CLI, but this app knows its own version natively (Info.plist,
    /// stamped by build-dmg.sh) and compares it client-side against the
    /// same latest-installer version. Row shapes match the shared
    /// contract: "✓ X: up to date" / "⬆ X: vY available" /
    /// "? X: unknown — no internet access".
    private func parseHostStatus(_ parsed: [String: Any]) -> HostUpdateStatus {
        var out = HostUpdateStatus()
        guard let hostComponents = parsed["host_components"] as? [[String: Any]] else {
            return out   // old fp binary — no host fields, omit the section
        }
        out.present = true
        if let url = parsed["installer_release_url"] as? String, !url.isEmpty {
            out.releaseURL = url
        }
        out.anyUpdate = parsed["host_any_update_available"] as? Bool ?? false
        let probeFailed = parsed["host_probe_failed"] as? Bool ?? false

        // Rows straight from the JSON (the Go side emits exactly one:
        // "fp CLI"). All host components share one latest version — the
        // installer release — so remember any real one for our own row.
        var latest = ""
        for comp in hostComponents {
            let name = comp["name"] as? String ?? "?"
            let errorKind = comp["error_kind"] as? String ?? ""
            let compLatest = normalizedVersion(comp["latest_version"] as? String ?? "")
            if isRealVersion(compLatest) { latest = compLatest }
            if !errorKind.isEmpty {
                out.lines.append("  ?  \(name): unknown — no internet access")
            } else if !isRealVersion(compLatest) {
                // Probe succeeded but no release exists yet ("none") —
                // match the Go CLI/TUI rendering: up to date.
                out.lines.append("  ✓  \(name): up to date")
            } else if comp["update_available"] as? Bool ?? false {
                out.lines.append("  ⬆  \(name): v\(compLatest) available")
            } else {
                out.lines.append("  ✓  \(name): up to date")
            }
        }

        // Our own row. Same rule as the Go side: update_available =
        // (normalized installed != normalized latest) && latest is real.
        let installed = normalizedVersion(
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
        if probeFailed {
            out.lines.append("  ?  Menu bar app: unknown — no internet access")
        } else if !isRealVersion(latest) {
            // No release published yet ("none") — up to date, matching Go.
            out.lines.append("  ✓  Menu bar app: up to date")
        } else if installed != latest {
            out.lines.append("  ⬆  Menu bar app: v\(latest) available")
            out.anyUpdate = true
        } else {
            out.lines.append("  ✓  Menu bar app: up to date")
        }

        out.latestVersion = latest
        return out
    }

    /// Opens the installer releases page — host components (the fp CLI,
    /// this app) update by running the latest installer, never in place.
    private func openInstallerReleases(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the DIRECT download of the macOS installer for the latest
    /// version, so the user never has to choose a file from the releases
    /// page. `FalconPulsar-Setup.dmg` is a stable, unversioned asset name
    /// present on every release; the version only varies the tag in the
    /// path. Falls back to the releases page when we don't have a concrete
    /// version (probe failed / "none"). The browser (signed in to GitHub)
    /// downloads it — the tray can't fetch a private release asset itself.
    private func openInstallerDownload(_ host: HostUpdateStatus) {
        var urlString = host.releaseURL
        if !host.latestVersion.isEmpty {
            // …/releases  →  …/releases/download/v<ver>/FalconPulsar-Setup.dmg
            urlString = host.releaseURL + "/download/v\(host.latestVersion)/FalconPulsar-Setup.dmg"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Automatic update checking (passive)

    /// Toggles FP_UPDATE_CHECK_AUTO in .env and starts/stops the
    /// background timers to match. The checkmark re-reads the flag after
    /// the write, so a failed write (missing ~/falconpulsar) can't leave
    /// the menu claiming a state the .env doesn't hold.
    @objc func toggleAutoUpdateCheck() {
        setAutoUpdateCheckEnabled(!autoUpdateCheckEnabled)
        autoCheckMenuItem?.state = autoUpdateCheckEnabled ? .on : .off
        configureAutoUpdateChecks()
    }

    /// (Re)builds the auto-check timers from the current flag state.
    /// ON: one check ~2 minutes after launch/enable + one every 24h — at
    /// most once per 24h thereafter. OFF (the default): both timers torn
    /// down, zero background network traffic.
    private func configureAutoUpdateChecks() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
        autoCheckLaunchTimer?.invalidate()
        autoCheckLaunchTimer = nil
        guard autoUpdateCheckEnabled else { return }
        autoCheckLaunchTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.runBackgroundUpdateCheck()
        }
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.runBackgroundUpdateCheck()
        }
    }

    /// Background auto-check. Runs the same `fp update --json` probe as
    /// the menu action, but the result is PASSIVE ONLY: icon badge + the
    /// "Update available: vX" menu line. Never an NSAlert, never a
    /// download, never an apply — and silent on any failure.
    private func runBackgroundUpdateCheck() {
        // Re-read the flag at fire time: if the operator turned it off by
        // hand-editing .env after the timer was scheduled, do nothing —
        // OFF means zero background network traffic.
        guard autoUpdateCheckEnabled else { return }
        let fpBin = "\(homeDir)/bin/fp"
        guard FileManager.default.fileExists(atPath: fpBin) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let json = self.runArgs(fpBin, ["update", "--json"])
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let anyImageUpdate = parsed["any_update_available"] as? Bool ?? false
            DispatchQueue.main.async {
                let host = self.parseHostStatus(parsed)
                self.updatePassiveIndicator(anyImageUpdate: anyImageUpdate, host: host)
            }
        }
    }

    /// Applies the passive indicator from a parsed check result — and
    /// clears it again when a fresh check says everything is current, so
    /// the badge can't go stale. Main thread only (touches UI).
    private func updatePassiveIndicator(anyImageUpdate: Bool, host: HostUpdateStatus) {
        if anyImageUpdate || host.anyUpdate {
            // Prefer the concrete installer version for the label; image
            // updates are digest-shaped, so fall back to a generic line.
            pendingUpdateLabel = (host.anyUpdate && isRealVersion(host.latestVersion))
                ? "Update available: v\(host.latestVersion)"
                : "Update available"
        } else {
            pendingUpdateLabel = nil
        }

        if let item = updateAvailableItem {
            if let label = pendingUpdateLabel {
                item.title = label
                item.attributedTitle = inlineIconTitle(label, symbol: "update", color: .systemBlue, bold: true)
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        // Redraw the status icon so the badge appears/disappears.
        updateIcon(status)
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
        # Profile flags: see composeProfileArgs().
        exec docker compose \(composeProfileArgs().joined(separator: " ")) logs -f --tail 100
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
            runArgs("/bin/launchctl", ["unload", plistPath])
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
        NSWorkspace.shared.open(URL(string: "https://docs.falconpulsar.com/")!)
    }

    @objc func openRequestFeature() {
        NSWorkspace.shared.open(URL(string: "https://falconpulsar.com/roadmap#request-form")!)
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
            let problems = ConfigBackup.lastExportProblems
            if problems.isEmpty {
                ok.messageText = "Export complete"
                ok.informativeText = "Saved to \(url.path)\n\nKeep this file private — it contains your configuration, encrypted with your admin credentials."
            } else {
                // The file is still written — a partial backup beats none — but
                // it must never be presented as a finished one. A backup missing
                // whole sections restores without complaint and leaves those
                // parts of the plant empty.
                ok.messageText = "Export INCOMPLETE — \(problems.count) item(s) missing"
                ok.informativeText = "Saved to \(url.path), but these could NOT be captured:\n\n"
                    + problems.map { "• \($0)" }.joined(separator: "\n")
                    + "\n\nRestoring this file will not bring the listed items back. Check that the stack is running (Start Stack), then export again."
                ok.alertStyle = .warning
            }
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
            let failed = ConfigBackup.lastImportErrorCount
            if failed > 0 {
                ok.messageText = "Import completed with \(failed) problem(s)"
                ok.informativeText = "Some items were rejected by the server (for example a datasource or mapping), so those series may have no source. Your time-series data is intact — check the Core logs (docker logs falconpulsar-core), then Restart Stack."
                ok.alertStyle = .warning
            } else {
                ok.messageText = "Import complete"
                ok.informativeText = "Restart the stack (Restart Stack) for all changes to take effect."
            }
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
        // 528 (was 480): the component grid now has a third row (AI Engine +
        // optional Command Center) below Core/Compose/Web UI/AI Capabilities.
        let h: CGFloat = 528
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
        //
        // Sized to its text, never to a constant. It used to be a hardcoded
        // 150pt: fine at "v0.1.4", and by "QuickDock  v0.1.4-alpha.67" the
        // label was ~187pt, so the pill's edges peeked out from BEHIND the
        // middle of the words and read as a stray shadow. A version string
        // only ever changes length, so the container has to measure it —
        // that also holds when 1.0 drops the "-alpha.NN" and it gets shorter.

        // Pull our own version from Info.plist (CFBundleShortVersionString).
        // build-dmg.sh writes it from FP_VERSION at build time, so a CI build
        // off tag v0.1.4-alpha.1 lands here as "0.1.4-alpha.1". Falls back to
        // "dev" only when running an unbundled debug build.
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        // "QuickDock", not "Installer". This window belongs to the menu-bar
        // app; the installer is a DIFFERENT app that also exists ("FalconPulsar
        // Installer.app"), so the old label named the wrong one. The number is
        // still the distribution version — QuickDock ships from the same
        // VERSION file, so it is equally this app's version.
        let verFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let verString = "QuickDock  v\(appVersion)"
        let verTextW = (verString as NSString).size(withAttributes: [.font: verFont]).width
        let pillW = ceil(verTextW) + 28   // 14pt of breathing room each side
        let verBg = NSView(frame: NSRect(x: (w - pillW) / 2, y: h - 260, width: pillW, height: 26))
        verBg.wantsLayer = true
        verBg.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        verBg.layer?.cornerRadius = 13
        view.addSubview(verBg)

        let verLabel = NSTextField(labelWithString: verString)
        verLabel.frame = NSRect(x: 0, y: h - 260, width: w, height: 26)
        verLabel.alignment = .center
        verLabel.font = verFont
        verLabel.textColor = NSColor(white: 0.8, alpha: 1)
        view.addSubview(verLabel)

        // ── Component grid with checkmarks ──
        // Each component shows its real version (from OCI labels) plus a
        // build-identifier suffix (short revision SHA) so support requests
        // pin the exact build. Compose row reads the engine version from
        // `docker compose version --short` instead of the static "v2".
        let coreInfo = getContainerInfo("falconpulsar-core")
        let uiInfo = getContainerInfo("falconpulsar-ui")
        let gwInfo = getContainerInfo("falconpulsar-ai-gateway")
        let engInfo = getContainerInfo("falconpulsar-ai-engine")
        let composeVer = getComposeVersion()

        // AI Engine is standard; Command Center appears when the install opted in.
        var components: [(String, String, Bool)] = [
            ("Core Engine", coreInfo.displayString, coreRunning),
            ("Compose", composeVer, true),
            ("Web UI", uiInfo.displayString, uiRunning),
            ("AI Capabilities", gwInfo.displayString, gatewayRunning),
            ("AI Engine", engInfo.displayString, engineRunning)
        ]
        // Opted in, OR actually up. A running Command Center must not be
        // omitted from the grid because its .env could not be read.
        if copilotEnabled || copilotRunning {
            components.append(("Command Center",
                getContainerInfo("falconpulsar-copilot").displayString, copilotRunning))
        }

        // 2x2 grid of 2-line cells. Each cell:
        //
        //   ✓  Core Engine                     ← top line: check + name (label)
        //      0.1.0-alpha.1 (58b896f)         ← bottom line: version (data)
        //
        // Previous layout put name and version on the same line, which
        // worked when versions were short ("latest", "v2") but truncated
        // and overflowed the next column the moment we started rendering
        // real semvers + revision SHAs. Two-line cells give the version
        // string the entire column width to render in.
        //
        // colW = 230 column width, indent = 22 (under the name, not the
        // check), version field width = 200 (leaves an 8-pixel safety
        // gap to the next column's check icon).
        let gridY = h - 310
        let colW: CGFloat = 230
        let leftX: CGFloat = 45
        let rowH: CGFloat = 48          // was 32 (single-line); 48 gives room for 2 stacked labels + breathing space
        let lineGap: CGFloat = 22       // vertical distance between the two lines within a cell

        for (i, (name, ver, ok)) in components.enumerated() {
            let col = CGFloat(i % 2)
            let row = CGFloat(i / 2)
            let cx = leftX + col * colW
            let cy = gridY - row * rowH    // bottom-line baseline; top line sits at cy + lineGap

            // ── Top line: check + name ──
            let check = NSTextField(labelWithString: ok ? "✓" : "✗")
            check.frame = NSRect(x: cx, y: cy + lineGap, width: 20, height: 18)
            check.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            check.textColor = ok ? NSColor.systemGreen : NSColor.systemRed
            view.addSubview(check)

            // No trailing colon — the version below stands on its own line, so the
            // "Name: <inline value>" punctuation no longer makes sense.
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.frame = NSRect(x: cx + 22, y: cy + lineGap, width: 200, height: 18)
            nameLabel.font = NSFont.systemFont(ofSize: 12)
            nameLabel.textColor = NSColor(white: 0.65, alpha: 1)
            view.addSubview(nameLabel)

            // ── Bottom line: version (indented under name) ──
            // 200px width fits "a.b.c-rc.10 (1234567)" (~22 chars) at SF Mono 11pt
            // with a comfortable 8px buffer to the next column — no truncation,
            // no overflow.
            let verText = NSTextField(labelWithString: ver)
            verText.frame = NSRect(x: cx + 22, y: cy, width: 200, height: 18)
            // Shrink to fit rather than truncate. The comment above budgets
            // ~22 characters at 11pt; Core reports a `git describe` string
            // that is longer, and the column silently cut the tail — which is
            // the half that carries the build id a support request needs.
            // Losing a point of size is always better than losing the SHA.
            verText.font = fittedMonoFont(for: ver, width: 200, base: 11, floor: 8.5)
            verText.textColor = NSColor(white: 0.9, alpha: 1)
            view.addSubview(verText)
        }

        // ── Links ──
        // Position relative to the grid bottom rather than gridY directly,
        // so that bumping rowH (cell height) automatically pushes the
        // links down without us having to remember to update this constant
        // too. Bottom of last row = gridY - rowH; links sit ~37px below.
        let linksY = (gridY - 2 * rowH) - 37
        let linkData: [(String, String)] = [
            ("Documentation", "https://docs.falconpulsar.com/"),
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
        "https://docs.falconpulsar.com/",
        "https://github.com/FalconPulsar/falconpulsar-installer/releases",
        "https://github.com/FalconPulsar/falconpulsar-installer/blob/main/LICENSE"
    ]

    @objc func aboutLinkClicked(_ sender: NSButton) {
        if sender.tag < aboutLinks.count {
            NSWorkspace.shared.open(URL(string: aboutLinks[sender.tag])!)
        }
    }

    /// Per-container metadata read from OCI image labels via `docker inspect`.
    /// `version` and `revision` come from the Open Container Initiative
    /// standard labels (`org.opencontainers.image.version`, `.revision`,
    /// `.created`). When the version label is missing or carries a non-semver
    /// placeholder like `"main"` or `"master"` (a real bug we've seen on the
    /// upstream image builds), we fall back to a 7-char prefix of the image
    /// digest — always available, cryptographically meaningful, unambiguous.
    /// `displayString` formats them for the About panel as
    ///   "0.3.7 (a03db27)"   when both label and revision are present
    ///   "0.3.7"              when only the label resolved
    ///   "a03db27"            when we fell back to the digest
    ///   "n/a"                when the container isn't running at all
    private struct ContainerInfo {
        let version: String
        let revision: String

        var displayString: String {
            if version == "n/a" { return "n/a" }
            if revision.isEmpty { return version }
            // Don't print the rev twice if version IS the digest fallback
            if version == revision { return version }
            // Nor when a `git describe` version already ENDS in it
            // (v0.1.4-alpha.89-5-g61ec2ad): appending "(61ec2ad)" repeats
            // the same seven characters, and the repetition is exactly what
            // overflowed this column and truncated the Core row.
            if version.contains(revision) { return version }
            return "\(version) (\(revision))"
        }
    }

    /// The largest monospaced size at which `text` still fits `width`.
    ///
    /// Steps down by half-points to `floor`, then gives up and returns the
    /// floor — at which point truncation is unavoidable and a smaller number
    /// is still more readable than an ellipsis.
    private func fittedMonoFont(for text: String, width: CGFloat,
                                base: CGFloat, floor: CGFloat) -> NSFont {
        var size = base
        while size > floor {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            if (text as NSString).size(withAttributes: [.font: font]).width <= width {
                return font
            }
            size -= 0.5
        }
        return NSFont.monospacedSystemFont(ofSize: floor, weight: .regular)
    }

    private func getContainerInfo(_ name: String) -> ContainerInfo {
        // One inspect call returning all 4 fields tab-separated. Note the
        // escaped braces in the Go template — `index` looks up the labels
        // by name, returning empty string for missing keys (which we
        // expect on older or upstream-mislabelled images).
        let format = "{{ index .Config.Labels \"org.opencontainers.image.version\" }}\t" +
                     "{{ index .Config.Labels \"org.opencontainers.image.revision\" }}\t" +
                     "{{ index .Config.Labels \"org.opencontainers.image.created\" }}\t" +
                     "{{ .Image }}"
        let (bin, argv) = dockerInvocation(["inspect", "--format", format, name])
        // Trim ONLY trailing newlines, NOT all whitespace. Containers
        // without any OCI labels emit "\t\t\t<imageId>" --
        // .whitespacesAndNewlines would strip the leading tabs,
        // collapsing 4 fields into 1 and putting the image digest where
        // labelVer is supposed to be. Subtle bug, took a live test to
        // surface it.
        let output = runArgs(bin, argv).trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
        if output.isEmpty {
            return ContainerInfo(version: "n/a", revision: "")
        }

        let parts = output.components(separatedBy: "\t")
        let labelVer = parts.indices.contains(0) ? parts[0] : ""
        let labelRev = parts.indices.contains(1) ? parts[1] : ""
        let imageId  = parts.indices.contains(3) ? parts[3] : ""

        // Branch-name placeholders that some image builds set instead of
        // a real semver. Treat them as missing so we fall back to digest.
        let placeholderVersions: Set<String> = ["", "main", "master", "develop", "latest", "HEAD"]

        let version: String
        if placeholderVersions.contains(labelVer) {
            // Strip "sha256:" prefix and take first 7 chars.
            let id = imageId.hasPrefix("sha256:") ? String(imageId.dropFirst(7)) : imageId
            version = id.isEmpty ? "n/a" : String(id.prefix(7))
        } else {
            version = labelVer
        }

        // Revision label is a full git SHA (40 chars). Truncate to 7 for
        // display, matching the convention of every other VCS surface.
        let revision = labelRev.isEmpty ? "" : String(labelRev.prefix(7))
        return ContainerInfo(version: version, revision: revision)
    }

    /// Docker Compose engine version (the v2 plugin shipped by Docker
    /// Desktop). Was previously hardcoded as "v2"; reading it gives us the
    /// real engine version (e.g. "v2.21.0") which is what users actually
    /// need to share with support when composing-related issues come up.
    private func getComposeVersion() -> String {
        let (bin, argv) = dockerInvocation(["compose", "version", "--short"])
        let output = runArgs(bin, argv).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return "v2" }
        return output.hasPrefix("v") ? output : "v\(output)"
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
        // Stop the background update checks too — mid-uninstall they'd
        // shell out to an fp binary that may already be gone. Nil them so
        // updateMenu()'s flag/timer resync can restore them if the
        // uninstall fails and polling resumes.
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
        autoCheckLaunchTimer?.invalidate()
        autoCheckLaunchTimer = nil
        updateIcon(.unknown)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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

            let succeeded: Bool
            var failureDetail = ""
            if let scriptPath = script {
                // Pass --force: the menu bar already authenticated the admin
                // in Swift (authenticateWithRetry or YES-bypass), so the bash
                // script should not try to prompt for credentials again via
                // /dev/tty (which isn't attached in a GUI-launched shell and
                // would just fail + exit without cleanup).
                //
                // FP_MENUBAR_UNINSTALL=1 tells the script we are its parent:
                // its usual first step — pkill FalconPulsarMenuBar — would
                // SIGTERM this very app, closing the output pipe and killing
                // the cleanup mid-run. With the flag set the script skips
                // that step; we quit ourselves after the completion alert.
                //
                // Branch on the script's exit status: a declined sudo prompt,
                // an errexit trip, or any non-zero exit must NOT be reported as
                // a clean uninstall.
                let result = self.runArgsStatus("/bin/bash", [scriptPath, purgeFlag, "--yes", "--force"],
                                                extraEnv: ["FP_MENUBAR_UNINSTALL": "1"])
                succeeded = result.status == 0
                if !succeeded {
                    let tail = self.lastLines(of: result.output)
                    failureDetail = tail.isEmpty
                        ? "The uninstall script exited with status \(result.status)."
                        : "The uninstall script exited with status \(result.status):\n\n\(tail)"
                }
            } else {
                succeeded = self.inlineUninstall(purge: purge)
                if !succeeded {
                    failureDetail = "Some components could not be removed (the menu bar app, its login item, or the stack folder may remain). See Console for details."
                }
            }

            DispatchQueue.main.async {
                let notification = NSAlert()
                notification.addButton(withTitle: "OK")
                if succeeded {
                    notification.messageText = "Uninstall Complete"
                    if purge {
                        notification.informativeText = "FalconPulsar has been completely removed."
                    } else {
                        notification.informativeText = "FalconPulsar has been removed. Your database is preserved at ~/falconpulsar/data"
                    }
                    notification.alertStyle = .informational
                    notification.runModal()

                    // Quit the menu bar app.
                    self.pollTimer?.invalidate()
                    self.statusItem.isVisible = false
                    NSApp.terminate(nil)
                } else {
                    notification.messageText = "Uninstall Failed"
                    notification.informativeText = failureDetail
                    notification.alertStyle = .warning
                    notification.runModal()

                    // The stack is (at least partly) still installed, so leave
                    // the app running for a retry and resume the health polling
                    // that runUninstall paused at its start.
                    self.pollHealth()
                    self.pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                        self?.pollHealth()
                    }
                }
            }
        }
    }

    /// Last `maxLines` non-empty lines of `output`, for surfacing a script's
    /// failure tail in an alert without dumping the whole transcript.
    private func lastLines(of output: String, maxLines: Int = 12) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Inline uninstall fallback when no uninstall.sh is found. Each step is
    /// best-effort: failures don't abort the chain because we're tearing down
    /// anyway. The two pipe/xargs-heavy steps (image cleanup, volume prune)
    /// stay on `shell()` because they genuinely need a shell — they don't
    /// interpolate any Swift-derived path. Returns false when a component that
    /// should be gone clearly remains (the app bundle, its login item, or —
    /// on purge — the stack folder), so the caller can report the failure.
    private func inlineUninstall(purge: Bool) -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let stackDir = "\(home)/falconpulsar"
        var ok = true

        // For TEARDOWN we want BOTH known profiles enabled unconditionally so
        // profile-gated services (the AI Engine) are in the compose model even
        // if FP_AI_ENGINE_ENABLED reads false right now — uninstall removes
        // everything regardless of the current enable state. Do NOT swap this
        // for composeProfileArgs() (which gates --profile engine on the live
        // enable flag); this mirrors the shared uninstall strategy.
        let teardownProfiles = ["--profile", "ai", "--profile", "engine", "--profile", "copilot"]

        // 1. compose down (plus --volumes on purge).
        var downArgs = ["compose"] + teardownProfiles + ["down", "--remove-orphans"]
        if purge { downArgs.append("--volumes") }
        let (dockerBin, dockerDownArgv) = dockerInvocation(downArgs)
        if fm.fileExists(atPath: stackDir) {
            _ = runArgs(dockerBin, dockerDownArgv, cwd: stackDir)
        }

        // 2. Remove project images + any falconpulsar/* images. Pipes/xargs
        // make this string-shaped; no Swift-interpolated paths involved.
        // Both teardown profiles, so profile-gated images are included even
        // against a profile-gated compose.yml.
        _ = shell("""
            IMAGES="$(cd ~/falconpulsar 2>/dev/null && docker compose \(teardownProfiles.joined(separator: " ")) config --images 2>/dev/null | sort -u)"
            if [ -n "$IMAGES" ]; then echo "$IMAGES" | xargs docker rmi -f 2>/dev/null || true; fi
            docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^falconpulsar/' | xargs -r docker rmi -f 2>/dev/null || true
            """)

        // 3. Volume prune (purge only). Same rationale: pipes/xargs.
        if purge {
            _ = shell("docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar' | xargs -r docker volume rm -f 2>/dev/null || true")
        }

        // 4. Remove ~/falconpulsar (purge: whole tree; keep: application
        // files only, mirroring uninstall.sh's keep semantics). Keep-data
        // mode preserves .env — it carries FP_GATEWAY_SECRET, which encrypts
        // the provider API keys inside the preserved ai_config.db; deleting
        // it would make a reinstall mint a fresh secret and permanently
        // orphan those keys.
        if purge {
            try? fm.removeItem(atPath: stackDir)
            if fm.fileExists(atPath: stackDir) { ok = false }
        } else {
            try? fm.removeItem(atPath: "\(stackDir)/compose.yml")
            try? fm.removeItem(atPath: "\(stackDir)/.docker")
            try? fm.removeItem(atPath: "\(stackDir)/bin")
        }

        // 5. Remove the menu bar app from both Applications locations.
        let appPaths = [
            "/Applications/FalconPulsar Menu Bar.app",
            "\(home)/Applications/FalconPulsar Menu Bar.app",
        ]
        for path in appPaths {
            try? fm.removeItem(atPath: path)
            if fm.fileExists(atPath: path) { ok = false }
        }

        // 6. Tear down the LaunchAgent.
        let uid = String(getuid())
        _ = runArgs("/bin/launchctl", ["bootout", "gui/\(uid)/com.falconpulsar.menubar"])
        let plistPath = "\(home)/Library/LaunchAgents/com.falconpulsar.menubar.plist"
        _ = runArgs("/bin/launchctl", ["unload", plistPath])
        try? fm.removeItem(atPath: plistPath)
        if fm.fileExists(atPath: plistPath) { ok = false }

        // 7. Drop the Launch Services registration so Finder forgets the app.
        _ = runArgs(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            ["-u", "/Applications/FalconPulsar Menu Bar.app"]
        )

        return ok
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

    /// Drains the process's combined output on a background thread WHILE the
    /// child runs, then waits for exit. Reading only after `waitUntilExit`
    /// deadlocks once the child outgrows the 64 KB pipe buffer, and any child
    /// that must outlive a hiccup in this app (uninstall.sh in particular)
    /// needs a reader that keeps the pipe open for its entire lifetime.
    private func drainAndWait(_ process: Process, _ pipe: Pipe) -> String {
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            data = handle.readDataToEndOfFile()
            drained.signal()
        }
        process.waitUntilExit()
        drained.wait()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Legacy helper that runs a command string via `/bin/bash -c`. Subject to
    /// shell parsing/quoting on every interpolated value, so prefer `runArgs`
    /// for any new call site that touches a path, filename, or container name.
    /// Kept for genuinely string-shaped commands that need pipes/redirection
    /// (e.g. `xargs docker rmi`).
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
        return drainAndWait(process, pipe)
    }

    /// Argv-form runner: launches `launchPath` with `args` directly, with no
    /// shell interpreter in the middle, so paths/filenames containing spaces
    /// or shell metacharacters are passed through verbatim. Returns combined
    /// stdout+stderr as a String for parity with `shell()`. `extraEnv`
    /// entries are merged over the inherited environment.
    @discardableResult
    private func runArgs(_ launchPath: String, _ args: [String], cwd: String? = nil,
                         extraEnv: [String: String] = [:]) -> String {
        return runArgsStatus(launchPath, args, cwd: cwd, extraEnv: extraEnv).output
    }

    /// Like `runArgs` but also surfaces the child's exit status, for callers
    /// that must branch on success vs. failure (the uninstall reporting path)
    /// rather than treat the run as best-effort. `status` is the process
    /// termination status, or -1 if the process could not be launched.
    private func runArgsStatus(_ launchPath: String, _ args: [String], cwd: String? = nil,
                               extraEnv: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd = cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        // Mirror the PATH augmentation shell() does so docker-credential-*
        // helpers resolve correctly when launchPath itself spawns docker
        // (e.g. install.sh, uninstall.sh, fp).
        var env = ProcessInfo.processInfo.environment
        let dockerBin = "/Applications/Docker.app/Contents/Resources/bin"
        let extra = "\(dockerBin):/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        for (key, value) in extraEnv {
            env[key] = value
        }
        process.environment = env
        do {
            try process.run()
        } catch {
            return (-1, "runArgs failed to launch \(launchPath): \(error)")
        }
        let output = drainAndWait(process, pipe)
        return (process.terminationStatus, output)
    }

    /// Resolve the docker CLI binary, mirroring the resolution order used
    /// by the Go side (console/internal/actions/actions.go: dockerPath()).
    /// Falls back to a bare "docker" lookup via /usr/bin/env if none of the
    /// canonical paths exist.
    private func dockerPath() -> String {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/usr/bin/docker",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        return "/usr/bin/env"   // runArgs("/usr/bin/env", ["docker", ...])
    }

    /// Builds (binary, argv) for invoking docker. When dockerPath() falls
    /// back to /usr/bin/env, prepends "docker" to argv so PATH lookup wins.
    private func dockerInvocation(_ args: [String]) -> (String, [String]) {
        let bin = dockerPath()
        if bin == "/usr/bin/env" {
            return (bin, ["docker"] + args)
        }
        return (bin, args)
    }
}
