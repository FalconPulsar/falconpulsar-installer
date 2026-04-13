import Foundation

enum InstallRunner {
    static func run(state: InstallerState) {
        let logFile = "/tmp/falconpulsar-install.log"

        func log(_ msg: String) {
            let line = "[\(timestamp())] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    FileManager.default.createFile(atPath: logFile, contents: data)
                }
            }
            DispatchQueue.main.async {
                state.installLog += msg + "\n"
            }
        }

        func timestamp() -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Date())
        }

        func updateStep(_ idx: Int, _ status: StepStatus) {
            DispatchQueue.main.async {
                state.steps[idx].status = status
            }
        }

        // Initialize log
        let header = """
        ================================================================
          FalconPulsar macOS Installer Log
          Version: 0.1.0
          Date: \(timestamp())
        ================================================================

        """
        try? header.write(toFile: logFile, atomically: true, encoding: .utf8)

        log("[info] macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("[info] Architecture: \(machineArch())")
        log("[info] User: \(NSUserName())")
        log("[info] Registry: \(state.registryUrl)")
        log("[info] Admin user: \(state.adminUser)")
        log("[info] Admin password: (not logged)")

        // Step 0: Pre-flight checks
        updateStep(0, .running)
        log("[info] Step 1/7: Pre-flight checks")

        guard let dockerPath = ShellRunner.findDocker() else {
            log("[error] Docker not found")
            updateStep(0, .failed)
            finish(state: state, success: false, error: "Docker is not installed. Install Docker Desktop, Colima, or OrbStack.")
            return
        }
        log("[info] Docker found at: \(dockerPath)")

        if !ShellRunner.isDockerRunning() {
            log("[error] Docker is not running")
            updateStep(0, .failed)
            finish(state: state, success: false, error: "Docker is installed but not running. Start Docker Desktop and try again.")
            return
        }
        log("[info] Docker is running")
        updateStep(0, .passed)

        // Step 1: Container runtime
        updateStep(1, .running)
        log("[info] Step 2/7: Container runtime")
        let (composeOut, composeCode) = ShellRunner.run("\(dockerPath) compose version 2>&1")
        if composeCode == 0 {
            log("[info] \(composeOut.trimmingCharacters(in: .whitespacesAndNewlines))")
            updateStep(1, .passed)
        } else {
            log("[error] Docker Compose v2 not available")
            updateStep(1, .failed)
            finish(state: state, success: false, error: "Docker Compose v2 is required but not available.")
            return
        }

        // Step 2: Registry access
        updateStep(2, .running)
        log("[info] Step 3/7: Registry access")
        if state.registrySkip {
            log("[info] Registry check skipped by user")
            updateStep(2, .skipped)
        } else {
            let result = ShellRunner.testRegistryAccess(
                registry: state.registryUrl,
                user: state.registryUser,
                pass: state.registryPass
            )
            log("[info] Registry test: \(result.message)")
            if result.success {
                updateStep(2, .passed)
            } else {
                updateStep(2, .failed)
                finish(state: state, success: false, error: "Cannot access registry: \(result.message)")
                return
            }
        }

        // Steps 3-6: Run the bash installer
        updateStep(3, .running)
        log("[info] Step 4/7: Running bash installer...")

        // Find the installer scripts
        let bundlePath = Bundle.main.bundlePath
        let possiblePaths = [
            "\(bundlePath)/../macos/install.sh",
            "\(bundlePath)/Contents/Resources/macos/install.sh",
            "\(NSHomeDirectory())/dev/falconpulsar-workspace/falconpulsar-installer/macos/install.sh",
            "/tmp/falconpulsar-installer/macos/install.sh"
        ]

        var installScript: String?
        for p in possiblePaths {
            let resolved = (p as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                installScript = resolved
                break
            }
        }

        guard let scriptPath = installScript else {
            log("[error] install.sh not found in any expected location")
            updateStep(3, .failed)
            finish(state: state, success: false, error: "Installer scripts not found. Run from the installer directory.")
            return
        }

        log("[info] Using installer at: \(scriptPath)")
        let repoRoot = (scriptPath as NSString).deletingLastPathComponent
        let parentRoot = (repoRoot as NSString).deletingLastPathComponent

        // Build the install command with env vars
        let envVars = [
            "FP_ASSUME_YES=1",
            "FP_LEGAL_ACCEPTED=1",
            "FP_ADMIN_USER='\(state.adminUser)'",
            "FP_ADMIN_PASS='\(state.adminPass.replacingOccurrences(of: "'", with: "'\\''"))'",
            "FP_REGISTRY='\(state.registryUrl)'",
            "FP_REGISTRY_USER='\(state.registryUser)'",
            "FP_REGISTRY_PASS='\(state.registryPass.replacingOccurrences(of: "'", with: "'\\''"))'",
            state.registrySkip ? "FP_REGISTRY_SKIP=1" : ""
        ].filter { !$0.isEmpty }.joined(separator: " ")

        let pathExport = "export PATH=\"/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:$PATH\""
        let cmd = "\(pathExport) && cd '\(parentRoot)' && \(envVars) bash '\(scriptPath)' --yes 2>&1"
        log("[info] Running: bash install.sh --yes")

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", cmd]
        process.launchPath = "/bin/bash"

        // Stream output line by line
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let line = String(data: data, encoding: .utf8) {
                log(line.trimmingCharacters(in: .newlines))

                // Update step status based on output
                DispatchQueue.main.async {
                    let l = line.lowercased()
                    if l.contains("step 3/") || l.contains("system user") {
                        updateStep(3, .passed)
                        updateStep(4, .running)
                    }
                    if l.contains("docker compose pull") || l.contains("pulling") {
                        updateStep(4, .running)
                    }
                    if l.contains("step 7/") || l.contains("docker compose up") || l.contains("starting") {
                        updateStep(4, .passed)
                        updateStep(5, .running)
                    }
                    if l.contains("is up and running") || l.contains("health") {
                        updateStep(5, .passed)
                        updateStep(6, .running)
                    }
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("[error] Failed to run install.sh: \(error)")
            updateStep(3, .failed)
            finish(state: state, success: false, error: "Failed to launch installer: \(error.localizedDescription)")
            return
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        log("[info] install.sh exited with code \(exitCode)")

        if exitCode == 0 {
            for i in 3...6 {
                updateStep(i, .passed)
            }
            log("[info] Installing menu bar app...")
            installMenuBarApp(log: log)
            finish(state: state, success: true, error: "")
        } else {
            // Mark remaining steps as failed
            for i in 0..<state.steps.count {
                if state.steps[i].status == .running || state.steps[i].status == .pending {
                    updateStep(i, .failed)
                }
            }
            finish(state: state, success: false, error: "Installation failed (exit code \(exitCode)). Check /tmp/falconpulsar-install.log for details.")
        }
    }

    private static func installMenuBarApp(log: (String) -> Void) {
        // Look for the menu bar app binary in known locations
        let bundlePath = Bundle.main.bundlePath
        let possiblePaths = [
            "\(bundlePath)/../menu-bar-app/.build/debug/FalconPulsarMenuBar",
            "\(bundlePath)/../menu-bar-app/.build/release/FalconPulsarMenuBar",
            "\(bundlePath)/Contents/Resources/FalconPulsarMenuBar",
            "\(NSHomeDirectory())/dev/falconpulsar-workspace/falconpulsar-installer/macos/menu-bar-app/.build/debug/FalconPulsarMenuBar"
        ]

        var menuBarBinary: String?
        for p in possiblePaths {
            let resolved = (p as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                menuBarBinary = resolved
                break
            }
        }

        guard let binary = menuBarBinary else {
            log("[warn] Menu bar app binary not found — skipping auto-install")
            return
        }
        log("[info] Found menu bar app at: \(binary)")

        // Create .app bundle in ~/Applications/
        let appDir = "\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app"
        let macosDir = "\(appDir)/Contents/MacOS"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)
            let destBinary = "\(macosDir)/FalconPulsarMenuBar"
            if fm.fileExists(atPath: destBinary) {
                try fm.removeItem(atPath: destBinary)
            }
            try fm.copyItem(atPath: binary, toPath: destBinary)

            // Create app icon from embedded logo
            let resourcesDir = "\(appDir)/Contents/Resources"
            try fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)
            createAppIcon(at: "\(resourcesDir)/AppIcon.icns")

            // Create Info.plist
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleExecutable</key>
                <string>FalconPulsarMenuBar</string>
                <key>CFBundleIdentifier</key>
                <string>com.falconpulsar.menubar</string>
                <key>CFBundleName</key>
                <string>FalconPulsar</string>
                <key>CFBundleVersion</key>
                <string>0.1.0</string>
                <key>CFBundleIconFile</key>
                <string>AppIcon</string>
                <key>LSUIElement</key>
                <true/>
            </dict>
            </plist>
            """
            try plist.write(toFile: "\(appDir)/Contents/Info.plist", atomically: true, encoding: .utf8)
            log("[info] Menu bar app installed to \(appDir)")
        } catch {
            log("[warn] Failed to install menu bar app: \(error)")
            return
        }

        // Create LaunchAgent for auto-start on login
        let launchAgentDir = "\(NSHomeDirectory())/Library/LaunchAgents"
        let launchAgentPath = "\(launchAgentDir)/com.falconpulsar.menubar.plist"
        do {
            try fm.createDirectory(atPath: launchAgentDir, withIntermediateDirectories: true)
            let agentPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.falconpulsar.menubar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app/Contents/MacOS/FalconPulsarMenuBar</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try agentPlist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
            log("[info] LaunchAgent created (auto-start on login)")
        } catch {
            log("[warn] Failed to create LaunchAgent: \(error)")
        }

        // Register the .app bundle with macOS LaunchServices so the
        // icon appears in Login Items, Finder, and Spotlight.
        let (_, _) = ShellRunner.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '\(appDir)'")
        log("[info] Registered app with LaunchServices")
        log("[info] Menu bar app ready at \(appDir) (will launch after user confirms)")
    }

    private static func finish(state: InstallerState, success: Bool, error: String) {
        DispatchQueue.main.async {
            state.installSuccess = success
            state.installError = error
            state.currentPage = .conclusion
        }
    }

    private static func createAppIcon(at path: String) {
        // Save the embedded logo as a PNG, then use sips + iconutil to
        // create a proper .icns file that macOS uses for Login Items etc.
        guard let logoData = Data(base64Encoded: LogoData.base64) else { return }

        let tmpDir = "/tmp/falconpulsar-iconset"
        let iconsetDir = "\(tmpDir)/AppIcon.iconset"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmpDir)
        try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

        // Write the source PNG
        let srcPng = "\(tmpDir)/icon-src.png"
        try? logoData.write(to: URL(fileURLWithPath: srcPng))

        // Generate all required sizes for .icns
        let sizes: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512)
        ]

        for (name, size) in sizes {
            let dest = "\(iconsetDir)/\(name)"
            let proc = Process()
            proc.launchPath = "/usr/bin/sips"
            proc.arguments = ["-z", "\(size)", "\(size)", srcPng, "--out", dest]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }

        // Convert iconset to icns
        let proc = Process()
        proc.launchPath = "/usr/bin/iconutil"
        proc.arguments = ["-c", "icns", iconsetDir, "-o", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        // Cleanup
        try? fm.removeItem(atPath: tmpDir)
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
