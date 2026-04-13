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

    private static func finish(state: InstallerState, success: Bool, error: String) {
        DispatchQueue.main.async {
            state.installSuccess = success
            state.installError = error
            state.currentPage = .conclusion
        }
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
