import AppKit
import Foundation
import UserNotifications

enum StackStatus {
    case unknown, running, partiallyRunning, stopped
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var coreRunning = false
    private var uiRunning = false
    private var gatewayRunning = false
    private var apiHealthy = false
    private var status: StackStatus = .unknown

    private let composePath = "\(NSHomeDirectory())/falconpulsar/compose.yml"
    private let homeDir = "\(NSHomeDirectory())/falconpulsar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(.unknown)

        buildMenu()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.pollHealth()
        }
        pollHealth()
    }

    // MARK: - Menu

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
        menu.addItem(NSMenuItem(title: "AI Gateway: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "REST API: checking...", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let openUI = NSMenuItem(title: "Open Web UI", action: #selector(openWebUI), keyEquivalent: "o")
        openUI.target = self
        openUI.attributedTitle = NSAttributedString(
            string: "Open Web UI",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(openUI)

        let start = NSMenuItem(title: "Start Stack", action: #selector(startStack), keyEquivalent: "")
        start.target = self
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Stack", action: #selector(stopStack), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        let restart = NSMenuItem(title: "Restart Stack", action: #selector(restartStack), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
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
        let gwConfig = NSMenuItem(title: "AI Gateway (gateway.yaml)", action: #selector(editGatewayConfig), keyEquivalent: "")
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

        menu.addItem(.separator())

        let autoStart = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStart.target = self
        autoStart.state = isAutoStartEnabled() ? .on : .off
        menu.addItem(autoStart)

        let docs = NSMenuItem(title: "Documentation", action: #selector(openDocumentation), keyEquivalent: "d")
        docs.target = self
        menu.addItem(docs)

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

        // Status items are at indices 2-5 (after header + separator)
        let statuses: [(Bool, String)] = [
            (coreRunning, "Core"),
            (uiRunning, "Web UI"),
            (gatewayRunning, "AI Gateway"),
            (apiHealthy, "REST API")
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

        // Enable/disable Start/Stop/Restart (indices 8, 9, 10 — after separator + Open Web UI)
        menu.item(at: 8)?.isEnabled = status != .running        // Start
        menu.item(at: 9)?.isEnabled = status != .stopped         // Stop
        menu.item(at: 10)?.isEnabled = status != .stopped        // Restart
    }

    // MARK: - Status Icon

    private func updateIcon(_ newStatus: StackStatus) {
        let color: NSColor
        let tooltip: String

        switch newStatus {
        case .running:
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1) // green
            tooltip = "FalconPulsar: Running"
        case .partiallyRunning:
            color = NSColor(red: 0.92, green: 0.70, blue: 0.03, alpha: 1) // yellow
            tooltip = "FalconPulsar: Partially running"
        case .stopped:
            color = NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1) // red
            tooltip = "FalconPulsar: Stopped"
        case .unknown:
            color = NSColor.gray
            tooltip = "FalconPulsar: Checking..."
        }

        statusItem.button?.image = createStatusImage(color: color)
        statusItem.button?.toolTip = tooltip
    }

    private func createStatusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw the falcon logo scaled to fit
        if let logo = LogoData.image {
            logo.draw(in: NSRect(origin: .zero, size: size),
                     from: NSRect(origin: .zero, size: logo.size),
                     operation: .sourceOver, fraction: 1.0)
        } else {
            // Fallback: "F" on dark circle
            let rect = NSRect(origin: .zero, size: size)
            NSColor(red: 0.05, green: 0.10, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: "F", attributes: attrs)
            let strSize = str.size()
            str.draw(at: NSPoint(
                x: (size.width - strSize.width) / 2,
                y: (size.height - strSize.height) / 2
            ))
        }

        // Status dot in bottom-right corner
        let dotSize: CGFloat = 6
        let dotX = size.width - dotSize - 1
        let dotY: CGFloat = 1
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX - 1, y: dotY - 1, width: dotSize + 2, height: dotSize + 2)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Health Polling

    private func pollHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            self.coreRunning = self.isContainerRunning("falconpulsar-core")
            self.uiRunning = self.isContainerRunning("falconpulsar-ui")
            self.gatewayRunning = self.isContainerRunning("falconpulsar-ai-gateway")
            self.apiHealthy = self.isAPIHealthy()

            let prev = self.status
            if self.coreRunning && self.uiRunning && self.gatewayRunning {
                self.status = self.apiHealthy ? .running : .partiallyRunning
            } else if self.coreRunning || self.uiRunning || self.gatewayRunning {
                self.status = .partiallyRunning
            } else {
                self.status = .stopped
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

    @objc func viewLogs() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(homeDir) && docker compose logs -f --tail 100"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
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
            // Remove auto-start
            shell("launchctl unload '\(plistPath)' 2>/dev/null")
            try? fm.removeItem(atPath: plistPath)
        } else {
            // Add auto-start
            let appPath = "\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app/Contents/MacOS/FalconPulsarMenuBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.falconpulsar.menubar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        }

        // Update the menu item state
        if let menu = statusItem.menu {
            for item in menu.items where item.title == "Start at Login" {
                item.state = isAutoStartEnabled() ? .on : .off
            }
        }
    }

    private func isAutoStartEnabled() -> Bool {
        return FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/Library/LaunchAgents/com.falconpulsar.menubar.plist")
    }

    @objc func openDocumentation() {
        NSWorkspace.shared.open(URL(string: "https://falconpulsar.com/docs")!)
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
            ("AI Gateway", gwVer, gatewayRunning)
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

        switch response {
        case .alertFirstButtonReturn:
            // Keep data
            runUninstall(purge: false)
        case .alertSecondButtonReturn:
            // Remove everything
            let confirm = NSAlert()
            confirm.messageText = "Are you sure?"
            confirm.informativeText = "This will permanently delete your FalconPulsar database and all data. This cannot be undone."
            confirm.alertStyle = .critical
            confirm.addButton(withTitle: "Delete Everything")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() == .alertFirstButtonReturn {
                runUninstall(purge: true)
            }
        default:
            break
        }
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
                self?.shell("bash '\(scriptPath)' \(purgeFlag) --yes 2>&1")
            } else {
                // Inline uninstall if script not found
                self?.shell("""
                    cd ~/falconpulsar 2>/dev/null && docker compose down --remove-orphans 2>/dev/null || true
                    docker rmi falconpulsar/core falconpulsar/ui falconpulsar/ai-gateway 2>/dev/null || true
                    \(purge ? "rm -rf ~/falconpulsar" : "rm -f ~/falconpulsar/compose.yml ~/falconpulsar/.env")
                    rm -rf ~/Applications/FalconPulsar\\ Menu\\ Bar.app 2>/dev/null || true
                    launchctl unload ~/Library/LaunchAgents/com.falconpulsar.menubar.plist 2>/dev/null || true
                    rm -f ~/Library/LaunchAgents/com.falconpulsar.menubar.plist 2>/dev/null || true
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
