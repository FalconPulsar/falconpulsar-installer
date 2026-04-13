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
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
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

    @objc func refreshStatus() {
        pollHealth()
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
