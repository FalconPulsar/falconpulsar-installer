import Foundation

enum InstallRunner {
    // Held so app termination can kill any running bash installer to avoid
    // orphaned subprocesses leaving the stack half-configured.
    static var activeProcess: Process?

    /// Kill any in-flight install.sh subprocess. Called from AppActivator
    /// on applicationWillTerminate.
    static func killActiveProcess() {
        guard let p = activeProcess, p.isRunning else { return }
        p.terminate()
        // Give bash a moment to clean up, then SIGKILL if still alive.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

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

        // Verify bundled assets are present BEFORE we touch anything on the
        // user's system — all-or-nothing install policy.
        if let resourcePath = Bundle.main.resourcePath {
            let required = ["FalconPulsar Menu Bar.app", "fp"]
            for name in required {
                let p = "\(resourcePath)/\(name)"
                if !FileManager.default.fileExists(atPath: p) {
                    log("[error] Installer is incomplete: missing \(name) in Resources")
                    updateStep(0, .failed)
                    finish(state: state, success: false, error:
                        "Installer is incomplete — missing bundled resource: \(name). " +
                        "Re-download FalconPulsar-Setup.dmg and try again.")
                    return
                }
            }
            log("[info] Bundled resources verified")
        }

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

        // Pre-step: handle existing installation based on chosen action
        if !state.existing.isEmpty {
            log("[info] Install action: \(state.installAction.rawValue)")
            switch state.installAction {
            case .fresh:
                log("[info] Fresh install — tearing down existing stack and deleting data")
                let home = "\(NSHomeDirectory())/falconpulsar"
                _ = ShellRunner.run("cd '\(home)' && \(dockerPath) compose down -v 2>&1", timeout: 60)
                for c in state.existing.containers {
                    _ = ShellRunner.run("\(dockerPath) rm -f '\(c)' 2>&1")
                }
                _ = ShellRunner.run("/bin/rm -rf '\(home)'")
                log("[info] Stack and data removed")
            case .reinstall:
                log("[info] Reinstall — stopping containers (data preserved)")
                let home = "\(NSHomeDirectory())/falconpulsar"
                _ = ShellRunner.run("cd '\(home)' && \(dockerPath) compose down 2>&1", timeout: 60)
            case .upgrade:
                log("[info] Upgrade — stack files and data left untouched")
            }
            if state.removeCachedImages {
                log("[info] Removing cached FalconPulsar images")
                _ = ShellRunner.run("\(dockerPath) images --filter reference='*falconpulsar*' -q | xargs \(dockerPath) rmi -f 2>&1")
            }
        }

        // Fast path: upgrade-in-place (existing stack dir is intact) — refresh
        // the product-managed stack files, pull, up -d, and health-gate.
        // Stacks that were never provisioned for the AI-Gateway (no service
        // token in .env, or a compose.yml without the service) need the full
        // bash installer to bootstrap it, so they fall through to that path.
        let stackHome = "\(NSHomeDirectory())/falconpulsar"
        var upgradeFastPath = state.installAction == .upgrade
            && FileManager.default.fileExists(atPath: "\(stackHome)/compose.yml")
        if upgradeFastPath {
            let envText = (try? String(contentsOfFile: "\(stackHome)/.env", encoding: .utf8)) ?? ""
            let composeText = (try? String(contentsOfFile: "\(stackHome)/compose.yml", encoding: .utf8)) ?? ""
            let hasApiKey = envText.split(separator: "\n")
                .contains { $0.hasPrefix("FP_API_KEY=") && $0.count > "FP_API_KEY=".count }
            let hasGatewayService = composeText.split(separator: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "ai-gateway:" }
            if !hasApiKey || !hasGatewayService {
                log("[info] Existing stack lacks AI-Gateway provisioning — running the full installer to migrate")
                upgradeFastPath = false
            }
        }
        if upgradeFastPath {
            updateStep(3, .running)

            // Refresh the product-managed stack files from the installer
            // payload so upgrades pick up compose/nginx changes. User-managed
            // files (.env, gateway.yaml) are left alone; gateway.yaml is only
            // created if it went missing.
            if let sharedDir = findSharedDir() {
                for name in ["compose.yml", "nginx.conf"] {
                    let src = "\(sharedDir)/\(name)"
                    guard FileManager.default.fileExists(atPath: src) else { continue }
                    do {
                        let dest = "\(stackHome)/\(name)"
                        if FileManager.default.fileExists(atPath: dest) {
                            try FileManager.default.removeItem(atPath: dest)
                        }
                        try FileManager.default.copyItem(atPath: src, toPath: dest)
                        log("[info] Updated \(name) from installer bundle")
                    } catch {
                        log("[warn] Could not update \(name): \(error)")
                    }
                }
                // fileExists(atPath:) alone returns true for a DIRECTORY at
                // this path — which is exactly what Docker plants when the
                // stack was ever started while gateway.yaml was missing
                // (bind-mount sources are auto-created as directories). A
                // directory here means the gateway crash-loops and the
                // upgrade dies at the health gate, so replace it with the
                // bundled default instead of skipping the restore.
                let gatewayCfg = "\(stackHome)/gateway.yaml"
                var gatewayCfgIsDir: ObjCBool = false
                let gatewayCfgExists = FileManager.default.fileExists(atPath: gatewayCfg, isDirectory: &gatewayCfgIsDir)
                if gatewayCfgExists && gatewayCfgIsDir.boolValue {
                    log("[warn] gateway.yaml is a directory (Docker bind-mount artifact) — replacing it with the bundled default")
                    do {
                        try FileManager.default.removeItem(atPath: gatewayCfg)
                    } catch {
                        log("[warn] Could not remove directory at gateway.yaml: \(error)")
                    }
                }
                if !FileManager.default.fileExists(atPath: gatewayCfg),
                   FileManager.default.fileExists(atPath: "\(sharedDir)/gateway.yaml") {
                    try? FileManager.default.copyItem(atPath: "\(sharedDir)/gateway.yaml", toPath: gatewayCfg)
                    log("[info] Restored missing gateway.yaml")
                }
            } else {
                log("[warn] Bundled stack files not found — keeping the existing compose.yml")
            }

            // AI capabilities are mandatory: normalize any legacy opt-out
            // left in .env (older fp/tray binaries still read this key).
            scrubAIGatewayFlag(envPath: "\(stackHome)/.env", log: log)
            updateStep(3, .passed)

            // "--profile ai" is legacy compose compat (pre-mandatory-gateway
            // installs gate ai-gateway behind that profile); it is a no-op on
            // current compose files.
            updateStep(4, .running)
            log("[info] Running: docker compose --profile ai pull")
            let (out1, pullCode) = ShellRunner.run("cd '\(stackHome)' && \(dockerPath) compose --profile ai pull 2>&1", timeout: 600)
            log(out1)
            if pullCode != 0 {
                log("[warn] docker compose pull exited \(pullCode) — continuing with cached images")
            }
            updateStep(4, .passed)

            updateStep(5, .running)
            log("[info] Running: docker compose --profile ai up -d")
            let (out2, code) = ShellRunner.run("cd '\(stackHome)' && \(dockerPath) compose --profile ai up -d 2>&1", timeout: 180)
            log(out2)
            if code != 0 {
                updateStep(5, .failed)
                finish(state: state, success: false, error: "docker compose up failed (exit \(code)). See /tmp/falconpulsar-install.log.")
                return
            }
            updateStep(5, .passed)

            updateStep(6, .running)
            if let healthError = waitForStackHealthy(dockerPath: dockerPath, home: stackHome, log: log) {
                updateStep(6, .failed)
                finish(state: state, success: false, error: healthError)
                return
            }
            updateStep(6, .passed)

            log("[info] Installing menu bar app...")
            installMenuBarApp(log: log)
            log("[info] Installing fp console CLI...")
            installFpCli(log: log)
            finish(state: state, success: true, error: "")
            return
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
            finish(state: state, success: false, error:
                "Installer scripts not found in the app bundle. " +
                "Re-download FalconPulsar-Setup.dmg and try again, or install from Terminal: " +
                "curl -fsSL https://get.falconpulsar.com/macos | bash")
            return
        }

        log("[info] Using installer at: \(scriptPath)")
        let repoRoot = (scriptPath as NSString).deletingLastPathComponent
        let parentRoot = (repoRoot as NSString).deletingLastPathComponent

        // Build the install env. We write the secrets to a 0600-mode temp
        // file and source it from inside bash — this keeps FP_ADMIN_PASS
        // and FP_REGISTRY_PASS off the bash subprocess command line where
        // `ps eww` could harvest them.
        func sh(_ s: String) -> String {
            // Single-quote escape for bash: ' -> '\''
            return s.replacingOccurrences(of: "'", with: "'\\''")
        }
        // Point install.sh at the fp binary embedded inside Installer.app
        // (Contents/Resources/fp). Without this, fp_install_cli would try
        // to download from GitHub releases — which fails when the version
        // isn't tagged, leaving the user with `fp: command not found`.
        let bundledFp = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Resources/fp")

        let envLines = [
            "export FP_ASSUME_YES=1",
            "export FP_LEGAL_ACCEPTED=1",
            "export FP_INSTALL_ACTION='\(sh(state.installAction.rawValue))'",
            "export FP_ADMIN_USER='\(sh(state.adminUser))'",
            "export FP_ADMIN_PASS='\(sh(state.adminPass))'",
            "export FP_REGISTRY='\(sh(state.registryUrl))'",
            "export FP_REGISTRY_USER='\(sh(state.registryUser))'",
            "export FP_REGISTRY_PASS='\(sh(state.registryPass))'",
            state.registrySkip ? "export FP_REGISTRY_SKIP=1" : "",
            // Back-compat for older fp/tray binaries that read this key from
            // .env. The installer itself no longer branches on it — AI
            // capabilities are always installed.
            "export FP_AI_GATEWAY_ENABLED=true",
            // Front-door HTTPS declaration. Drives the Secure flag and
            // __Host- prefix on session cookies. The bash installer's
            // `prompt_transport_mode` reads this and skips the prompt.
            "export FP_COOKIE_SECURE=\(state.cookieSecure ? "true" : "false")",
            // Use the bundled fp binary instead of downloading from GitHub
            // releases. Path is the macOS-arm64 binary embedded by build-dmg.sh.
            FileManager.default.fileExists(atPath: bundledFp)
                ? "export FP_LOCAL_FP_BINARY='\(sh(bundledFp))'" : "",
            // GUI install ALWAYS adds fp to PATH — without this the user
            // sees `fp: command not found` even though we just installed it.
            "export FP_ADD_TO_PATH=1"
        ].filter { !$0.isEmpty }.joined(separator: "\n") + "\n"

        let envFile = "/tmp/fp-install-env-\(getpid()).sh"
        do {
            // Create with restrictive perms FIRST (don't open + chmod, as the
            // window between open and chmod is when the secret is exposed).
            FileManager.default.createFile(atPath: envFile, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
            try envLines.write(toFile: envFile, atomically: true, encoding: .utf8)
            // Re-apply perms after `write(toFile:atomically:)` (atomic write
            // recreates the inode and may use the default umask).
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: envFile)
        } catch {
            log("[error] Failed to stage installer env: \(error)")
            finish(state: state, success: false, error: "Failed to stage installer environment.")
            return
        }

        let pathExport = "export PATH=\"/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:$PATH\""
        // Source the env file then immediately rm it; if the bash exits
        // unexpectedly the temp file is also wiped by InstallRunner cleanup
        // below (defer-style via removeItem after waitUntilExit).
        let cmd = """
        \(pathExport) && cd '\(parentRoot)' && \
        source '\(envFile)' && rm -f '\(envFile)' && \
        bash '\(scriptPath)' --yes 2>&1
        """
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

                // Update step status based on output. Tokens track the
                // log_step/log_info lines macos/install.sh actually emits.
                DispatchQueue.main.async {
                    let l = line.lowercased()
                    if l.contains("step 4/") {          // "step 4/6 — stack files"
                        updateStep(3, .passed)
                    }
                    if l.contains("step 5/") || l.contains("pulling") {
                        updateStep(3, .passed)
                        updateStep(4, .running)
                    }
                    if l.contains("starting core") {    // pull done, stack coming up
                        updateStep(4, .passed)
                        updateStep(5, .running)
                    }
                    if l.contains("verifying installation health") {
                        updateStep(5, .passed)
                        updateStep(6, .running)
                    }
                }
            }
        }

        // Track the running subprocess so we can kill it if the user quits
        // the app mid-install. Otherwise bash keeps running as an orphan,
        // potentially leaving containers in a half-up state.
        InstallRunner.activeProcess = process

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("[error] Failed to run install.sh: \(error)")
            updateStep(3, .failed)
            InstallRunner.activeProcess = nil
            finish(state: state, success: false, error: "Failed to launch installer: \(error.localizedDescription)")
            return
        }

        InstallRunner.activeProcess = nil
        // Belt-and-braces: ensure the env file is gone even if bash crashed
        // before reaching the inline `rm -f`.
        try? FileManager.default.removeItem(atPath: envFile)
        pipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        log("[info] install.sh exited with code \(exitCode)")

        if exitCode == 0 {
            for i in 3...6 {
                updateStep(i, .passed)
            }
            log("[info] Installing menu bar app...")
            installMenuBarApp(log: log)
            log("[info] Installing fp console CLI...")
            installFpCli(log: log)
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

    /// Locates the shared/ directory of the installer payload (sibling of
    /// macos/), trying the same candidate roots used to find install.sh.
    private static func findSharedDir() -> String? {
        let bundlePath = Bundle.main.bundlePath
        let candidates = [
            "\(bundlePath)/../shared",
            "\(bundlePath)/Contents/Resources/shared",
            "\(NSHomeDirectory())/dev/falconpulsar-workspace/falconpulsar-installer/shared",
            "/tmp/falconpulsar-installer/shared"
        ]
        for p in candidates {
            let resolved = (p as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: "\(resolved)/compose.yml") {
                return resolved
            }
        }
        return nil
    }

    /// Forces FP_AI_GATEWAY_ENABLED=true in an existing .env. The installer
    /// no longer reads this key, but older fp/tray binaries still do —
    /// normalizing a legacy `false` keeps them from treating the mandatory
    /// AI-Gateway as switched off.
    private static func scrubAIGatewayFlag(envPath: String, log: (String) -> Void) {
        guard let envText = try? String(contentsOfFile: envPath, encoding: .utf8),
              envText.contains("FP_AI_GATEWAY_ENABLED=") else { return }
        let lines = envText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fixed = lines.map { $0.hasPrefix("FP_AI_GATEWAY_ENABLED=") ? "FP_AI_GATEWAY_ENABLED=true" : $0 }
        guard fixed != lines else { return }
        do {
            try fixed.joined(separator: "\n").write(toFile: envPath, atomically: true, encoding: .utf8)
            // The atomic write recreates the inode — restore the 0600 mode
            // the installer gives .env (it holds the service token).
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath)
            log("[info] Normalized FP_AI_GATEWAY_ENABLED=true in .env")
        } catch {
            log("[warn] Could not update .env: \(error)")
        }
    }

    /// Polls service health after an upgrade's `compose up`, mirroring the
    /// checks macos/install.sh performs on fresh installs: core's Docker
    /// healthcheck, the AI-Gateway /health endpoint, and a running ui
    /// container. Returns nil on success or a user-facing error message.
    private static func waitForStackHealthy(dockerPath: String, home: String,
                                            log: (String) -> Void) -> String? {
        log("[info] Waiting for core to become healthy...")
        var coreHealthy = false
        var deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let (out, _) = ShellRunner.run("\(dockerPath) inspect -f '{{.State.Health.Status}}' falconpulsar-core 2>/dev/null")
            let status = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == "healthy" { coreHealthy = true; break }
            if status == "unhealthy" { break }
            Thread.sleep(forTimeInterval: 3)
        }
        guard coreHealthy else {
            return "falconpulsar-core did not become healthy. Check: docker logs falconpulsar-core"
        }
        log("[info] core is healthy")

        // AI-Gateway health endpoint — honor a custom FP_GATEWAY_PORT and
        // FP_GATEWAY_BIND from .env; only accept safe values before
        // interpolating into a shell command. A 0.0.0.0 (all-interfaces)
        // bind is reachable on loopback, so probe 127.0.0.1 for it; a
        // specific address must be probed directly.
        var gatewayPort = "7436"
        var gatewayHost = "127.0.0.1"
        if let env = try? String(contentsOfFile: "\(home)/.env", encoding: .utf8) {
            for line in env.split(separator: "\n") {
                if line.hasPrefix("FP_GATEWAY_PORT=") {
                    let v = line.dropFirst("FP_GATEWAY_PORT=".count)
                        .trimmingCharacters(in: .whitespaces)
                    if v.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
                        gatewayPort = v
                    }
                } else if line.hasPrefix("FP_GATEWAY_BIND=") {
                    let v = line.dropFirst("FP_GATEWAY_BIND=".count)
                        .trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, v != "0.0.0.0",
                       v.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
                        gatewayHost = v
                    }
                }
            }
        }
        log("[info] Waiting for the AI-Gateway to become healthy...")
        var gatewayHealthy = false
        // 180 s matches the bash fp_wait_for_gateway_ready gate — a first
        // boot can spend the compose healthcheck's full 90 s start_period
        // on knowledge-base seeding.
        deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let (_, code) = ShellRunner.run("/usr/bin/curl -fsS -m 2 -o /dev/null 'http://\(gatewayHost):\(gatewayPort)/health' 2>/dev/null")
            if code == 0 { gatewayHealthy = true; break }
            Thread.sleep(forTimeInterval: 3)
        }
        guard gatewayHealthy else {
            return "AI-Gateway did not become healthy at \(gatewayHost):\(gatewayPort). Check: docker logs falconpulsar-ai-gateway"
        }
        log("[info] AI-Gateway is healthy")

        // The ui container has no healthcheck — running is the bar.
        let (uiOut, _) = ShellRunner.run("\(dockerPath) ps --filter name=falconpulsar-ui --filter status=running -q 2>/dev/null")
        guard !uiOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "falconpulsar-ui is not running. Check: docker logs falconpulsar-ui"
        }
        log("[info] ui is running")
        return nil
    }

    private static func installMenuBarApp(log: (String) -> Void) {
        let fm = FileManager.default

        // The menu bar .app is bundled inside this installer's Resources.
        guard let resourcePath = Bundle.main.resourcePath else {
            log("[warn] Installer has no resource path — skipping menu bar install")
            return
        }
        let sourceApp = "\(resourcePath)/FalconPulsar Menu Bar.app"
        guard fm.fileExists(atPath: sourceApp) else {
            log("[warn] Bundled menu bar app not found at \(sourceApp) — skipping")
            return
        }

        let destApp = "/Applications/FalconPulsar Menu Bar.app"

        // Kill any existing FalconPulsarMenuBar process so we can replace
        // the binary — copy/remove fails if the file is in use.
        _ = ShellRunner.run("/usr/bin/pkill -9 -f FalconPulsarMenuBar 2>/dev/null; sleep 0.5")
        log("[info] Killed any running menu bar instances")

        do {
            if fm.fileExists(atPath: destApp) {
                try fm.removeItem(atPath: destApp)
                log("[info] Removed existing \(destApp)")
            }
            try fm.copyItem(atPath: sourceApp, toPath: destApp)
            log("[info] Copied menu bar app from \(sourceApp)")
            // Only strip quarantine — do NOT re-sign. The bundle is already
            // signed by the DMG build step, and re-signing on the customer's
            // machine changes the signature each install, which poisons
            // LaunchServices caches.
            _ = ShellRunner.run("/usr/bin/xattr -dr com.apple.quarantine '\(destApp)' 2>/dev/null")
            log("[info] Stripped quarantine from menu bar app")
        } catch {
            log("[warn] Failed to copy menu bar app to /Applications: \(error)")
            return
        }

        // LaunchAgent for auto-start on login
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
                    <string>\(destApp)/Contents/MacOS/FalconPulsarMenuBar</string>
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

        let (_, _) = ShellRunner.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '\(destApp)'")
        log("[info] Registered app with LaunchServices")
    }

    /// Copies the bundled fp binary (Contents/Resources/fp) to
    /// ~/falconpulsar/bin/fp. Strips quarantine so Gatekeeper doesn't block
    /// first launch on the customer's machine.
    private static func installFpCli(log: (String) -> Void) {
        let fm = FileManager.default
        guard let resourcePath = Bundle.main.resourcePath else {
            log("[warn] fp CLI: no resource path, skipping install")
            return
        }
        let source = "\(resourcePath)/fp"
        guard fm.fileExists(atPath: source) else {
            log("[warn] fp CLI not bundled in installer — skipping (users can still run docker compose)")
            return
        }
        let home = "\(NSHomeDirectory())/falconpulsar"
        let binDir = "\(home)/bin"
        let dest = "\(binDir)/fp"
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: source, toPath: dest)
            _ = ShellRunner.run("/usr/bin/xattr -dr com.apple.quarantine '\(dest)' 2>/dev/null")
            _ = ShellRunner.run("/bin/chmod +x '\(dest)' 2>/dev/null")
            log("[info] fp CLI installed at \(dest)")
        } catch {
            log("[warn] fp CLI install failed: \(error)")
        }
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
