import SwiftUI

struct InstallerView: View {
    @StateObject private var state = InstallerState()

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch state.currentPage {
                case .welcome: WelcomePage(state: state)
                case .existing: ExistingInstallPage(state: state)
                case .legal: LegalPage(state: state)
                case .registry: RegistryPage(state: state)
                case .credentials: CredentialsPage(state: state)
                case .installing: InstallingPage(state: state)
                case .conclusion: ConclusionPage(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            HStack {
                if state.currentPage != .welcome && state.currentPage != .installing && state.currentPage != .conclusion {
                    Button("Back") { state.prevPage() }
                }
                Spacer()
                if state.currentPage == .conclusion {
                    Button("Close") { executeConclusionActions() }
                        .keyboardShortcut(.defaultAction)
                } else if state.currentPage == .installing {
                    // No buttons during install
                } else {
                    Button(state.currentPage == .credentials ? "Install" : "Continue") {
                        if state.currentPage == .credentials {
                            state.nextPage()
                            runInstall()
                        } else {
                            if state.currentPage == .welcome {
                                state.detectEnvironment()
                            }
                            state.nextPage()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProceed)
                }
            }
            .padding()
        }
    }

    var canProceed: Bool {
        switch state.currentPage {
        case .welcome: return state.prerequisitesOk
        case .existing: return state.canProceedFromExisting
        case .legal: return state.legalAccepted
        case .credentials: return state.canProceedFromCredentials
        default: return true
        }
    }

    func runInstall() {
        DispatchQueue.global(qos: .userInitiated).async {
            InstallRunner.run(state: state)
        }
    }

    private func unregisterSelfFromLaunchServices() {
        // When the installer runs from a mounted DMG, macOS registers that
        // ephemeral bundle path with LaunchServices, which leaves a stray
        // entry in Launchpad. Unregister our own bundle path so Launchpad
        // forgets about it.
        let bundlePath = Bundle.main.bundlePath
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = ShellRunner.run("'\(lsregister)' -u '\(bundlePath)' 2>/dev/null")
    }

    private func scheduleDMGEjectIfApplicable() {
        // If the installer is running from a mounted DMG, schedule a detached
        // shell to eject the volume shortly after the installer exits. We do
        // this via a detached process because the installer's own binary is
        // on the DMG — we can't eject from within our own process.
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Volumes/") else { return }
        let components = bundlePath.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else { return }
        let volumePath = "/Volumes/\(components[1])"
        // nohup + disown so the command survives our termination
        _ = ShellRunner.run("/bin/bash -c 'nohup sh -c \"sleep 2; /usr/bin/hdiutil detach \\\"\(volumePath)\\\" -force >/dev/null 2>&1\" >/dev/null 2>&1 &'")
    }

    func executeConclusionActions() {
        if state.installSuccess {
            if state.openWebUI {
                NSWorkspace.shared.open(URL(string: "http://localhost:8080")!)
            }
            if state.launchMenuBar {
                let logPath = "/tmp/falconpulsar-install.log"
                func addLog(_ s: String) {
                    if let h = FileHandle(forWritingAtPath: logPath) {
                        h.seekToEndOfFile()
                        h.write("[\(Date())] [menubar-launch] \(s)\n".data(using: .utf8) ?? Data())
                        h.closeFile()
                    }
                }
                let candidates = [
                    "/Applications/FalconPulsar Menu Bar.app",
                    "\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app",
                ]
                var launched = false
                for appPath in candidates where FileManager.default.fileExists(atPath: appPath) {
                    addLog("Found at \(appPath)")
                    // Launch detached so it survives installer termination
                    let result = ShellRunner.run("open -a '\(appPath)' 2>&1")
                    addLog("open -a exit=\(result.exitCode) output=\(result.output)")
                    launched = true
                    break
                }
                if !launched {
                    addLog("No menu bar app found in any candidate path")
                }
            }
            if state.viewLog {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/falconpulsar-install.log"))
            }
        }
        // Give a moment for actions to execute before quitting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            unregisterSelfFromLaunchServices()
            scheduleDMGEjectIfApplicable()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Welcome Page

struct WelcomePage: View {
    @ObservedObject var state: InstallerState
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 14) {
            if let img = LogoData.image {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            Text("FalconPulsar")
                .font(.system(size: 24, weight: .bold))
            Text("Self-host in 3 minutes. Your infrastructure, your data.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider().padding(.horizontal, 40)

            Text("Prerequisites")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                prereqRow(ok: state.dockerFound,
                          okText: "Docker CLI installed",
                          failText: "Docker CLI not installed")
                prereqRow(ok: state.dockerRunning,
                          okText: "Docker daemon running\(state.runtimeName.isEmpty ? "" : " (\(state.runtimeName))")",
                          failText: state.dockerFound ? "Docker installed but not running" : "Docker not running")
                prereqRow(ok: state.composeV2,
                          okText: "Docker Compose v2 available",
                          failText: "Docker Compose v2 not available")
            }
            .font(.callout)
            .padding(.horizontal, 40)

            actionBlock
                .padding(.top, 4)
                .frame(minHeight: 90, alignment: .top)

            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("Checking…").font(.caption2).foregroundColor(.secondary)
            }
            .frame(height: 16)
            .opacity(state.detecting ? 1 : 0)

            Spacer()

            HStack {
                Text("falconpulsar.com").foregroundColor(.blue)
                    .onTapGesture { NSWorkspace.shared.open(URL(string: "https://falconpulsar.com")!) }
                Text("  |  ").foregroundColor(.secondary)
                Text("(c) 2026 FalconPulsar Contributors").foregroundColor(.secondary)
            }
            .font(.caption)
        }
        .padding(24)
        .onAppear {
            state.detectEnvironment()
            state.detectExistingInstall()
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                if !state.prerequisitesOk {
                    state.detectEnvironment()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    @ViewBuilder
    private func prereqRow(ok: Bool, okText: String, failText: String) -> some View {
        Label(ok ? okText : failText,
              systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundColor(ok ? .green : .red)
    }

    @ViewBuilder
    private var actionBlock: some View {
        VStack(spacing: 8) {
            if state.prerequisitesOk {
                Label("All checks passed — ready to install",
                      systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.callout)
            } else if !state.dockerFound {
                Text("Install a container runtime:")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button("Docker Desktop") { open("https://www.docker.com/products/docker-desktop/") }
                    Button("OrbStack") { open("https://orbstack.dev/") }
                    Button("Rancher Desktop") { open("https://rancherdesktop.io/") }
                }
                Text("After installing, launch it — this page will update automatically.")
                    .font(.caption2).foregroundColor(.secondary)
            } else if !state.dockerRunning {
                Button("Start Docker") {
                    _ = ShellRunner.run("open -a Docker || open -a OrbStack || open -a 'Rancher Desktop' || colima start &")
                }
                .keyboardShortcut(.defaultAction)
                Text("Waiting for the daemon to come up…")
                    .font(.caption2).foregroundColor(.secondary)
            } else if !state.composeV2 {
                Text("Docker Compose v2 plugin is missing.")
                    .font(.caption).foregroundColor(.secondary)
                Text("Update Docker Desktop or install the compose plugin, then continue.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Legal Page

struct LegalPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you install")
                .font(.title2.bold())
            Text("Please review and accept the FalconPulsar legal terms")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("By installing FalconPulsar, you confirm you have read and agree to all four documents below. Click each link to open it in your default browser. You must check the box at the bottom to continue.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                LegalLink(title: "Terms of Service", url: "https://falconpulsar.com/terms/")
                LegalLink(title: "Privacy Policy", url: "https://falconpulsar.com/privacy/")
                LegalLink(title: "Acceptable Use Policy", url: "https://falconpulsar.com/aup/")
                LegalLink(title: "Security Policy", url: "https://falconpulsar.com/security/")
            }

            Spacer()

            Toggle("I have read and agree to all four documents", isOn: $state.legalAccepted)
                .toggleStyle(.checkbox)
        }
        .padding(30)
    }
}

struct LegalLink: View {
    let title: String
    let url: String

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundColor(.blue)
            Text(title)
                .foregroundColor(.blue)
                .underline()
                .onTapGesture {
                    NSWorkspace.shared.open(URL(string: url)!)
                }
        }
        .font(.callout)
    }
}

// MARK: - Registry Page

struct RegistryPage: View {
    @ObservedObject var state: InstallerState
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Container Registry")
                .font(.title2.bold())
            Text("Where should FalconPulsar pull images from?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("FalconPulsar can be pulled from any OCI-compliant registry: Docker Hub, GHCR, AWS ECR, Google Artifact Registry, Azure ACR, Quay, Harbor, or a private mirror. Leave the defaults if unsure.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text("Registry (hostname/namespace):")
                    .font(.callout.bold())
                TextField("falconpulsar", text: $state.registryUrl)
                    .textFieldStyle(.roundedBorder)

                Text("Username or org name (leave blank for public / anonymous):")
                    .font(.callout.bold())
                TextField("", text: $state.registryUser)
                    .textFieldStyle(.roundedBorder)

                Text("Password or token:")
                    .font(.callout.bold())
                SecureField("", text: $state.registryPass)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Test connection") {
                    testing = true
                    state.registryTestResult = ""
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = ShellRunner.testRegistryAccess(
                            registry: state.registryUrl,
                            user: state.registryUser,
                            pass: state.registryPass
                        )
                        DispatchQueue.main.async {
                            state.registryTestResult = result.message
                            state.registryTestOk = result.success
                            testing = false
                        }
                    }
                }
                .disabled(testing || state.registryUrl.isEmpty)

                if testing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if !state.registryTestResult.isEmpty {
                Label(state.registryTestResult,
                      systemImage: state.registryTestOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(state.registryTestOk ? .green : .red)
                    .font(.callout)
            }

            Spacer()

            Toggle("Skip the registry check (I already have docker login configured)",
                   isOn: $state.registrySkip)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .padding(30)
    }
}

// MARK: - Credentials Page

struct CredentialsPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Admin Credentials")
                .font(.title2.bold())

            Text("The password is NOT stored on disk. It is used once to create the admin user and then exchanged for a service token. Save it now.")
                .font(.callout)
                .foregroundColor(.secondary)

            Text("Admin username:").font(.callout.bold())
            TextField("admin", text: $state.adminUser)
                .textFieldStyle(.roundedBorder)

            Text("Admin password:").font(.callout.bold())
            HStack(spacing: 6) {
                SecureField("", text: $state.adminPass)
                    .textFieldStyle(.roundedBorder)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.adminPass, forType: .string)
                }
                .disabled(state.adminPass.isEmpty)
            }

            Text("Confirm password:").font(.callout.bold())
            SecureField("", text: $state.adminPassConfirm)
                .textFieldStyle(.roundedBorder)

            // Strength meter
            if !state.adminPass.isEmpty {
                HStack {
                    ProgressView(value: strengthValue, total: 1.0)
                        .tint(state.strengthColor)
                        .frame(width: 120)
                    Text(state.passwordStrength)
                        .foregroundColor(state.strengthColor)
                        .font(.callout.bold())
                    Spacer()
                    Text("\(state.adminPass.count)/10 characters (minimum 10)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            } else {
                Text("0/10 characters (minimum 10)")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Text("Use uppercase, lowercase, numbers, and symbols for a strong password.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Generate strong password") {
                state.generatePassword()
            }

            if state.passwordGenerated {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated password (save this now):").font(.caption).foregroundColor(.secondary)
                    Text(state.generatedPassword)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                }
            }

            if !state.adminPass.isEmpty && state.adminPass != state.adminPassConfirm && !state.adminPassConfirm.isEmpty {
                Label("Passwords do not match", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(30)
    }

    var strengthValue: Double {
        switch state.passwordStrength {
        case "Strong": return 1.0
        case "Medium": return 0.6
        default: return 0.3
        }
    }
}

// MARK: - Installing Page

struct InstallingPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installing FalconPulsar")
                .font(.title2.bold())
                .padding(.bottom, 8)

            ForEach(Array(state.steps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 8) {
                    stepIcon(step.status)
                    Text(step.name)
                        .foregroundColor(stepColor(step.status))
                        .font(step.status == .running ? .callout.bold() : .callout)
                }
            }

            Spacer()

            if !state.installLog.isEmpty {
                ScrollView {
                    Text(state.installLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(6)
            }
        }
        .padding(30)
    }

    func stepIcon(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            return Image(systemName: "circle").foregroundColor(.gray)
        case .running:
            return Image(systemName: "arrow.right.circle.fill").foregroundColor(.blue)
        case .passed:
            return Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            return Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .skipped:
            return Image(systemName: "minus.circle").foregroundColor(.gray)
        }
    }

    func stepColor(_ status: StepStatus) -> Color {
        switch status {
        case .running: return .primary
        case .failed: return .red
        case .skipped: return .gray
        default: return .primary
        }
    }
}

// MARK: - Conclusion Page

struct ConclusionPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(spacing: 16) {
            if let img = LogoData.image {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 60, height: 60)
            }

            if state.installSuccess {
                Text("FalconPulsar is installed!")
                    .font(.title.bold())
                    .foregroundColor(.green)

                Text("FalconPulsar is now installed and running on your Mac. Open the Web UI in any browser to log in with the admin credentials you set during this install. The admin password is NOT stored on disk anywhere — make sure you saved it.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            } else {
                Text("Installation failed")
                    .font(.title.bold())
                    .foregroundColor(.red)

                Text(state.installError)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider().padding(.horizontal, 40)

            if state.installSuccess {
                VStack(alignment: .leading, spacing: 6) {
                    ServiceRow(name: "Web UI", url: "http://localhost:8080")
                    ServiceRow(name: "REST API", url: "http://localhost:7433")
                    ServiceRow(name: "WebSocket", url: "ws://localhost:7434")
                    ServiceRow(name: "AI Gateway", url: "http://localhost:7436")
                }

                Divider().padding(.horizontal, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open Web UI in browser", isOn: $state.openWebUI)
                        .toggleStyle(.checkbox)
                    Toggle("Launch FalconPulsar Menu Bar", isOn: $state.launchMenuBar)
                        .toggleStyle(.checkbox)
                    Toggle("View install log", isOn: $state.viewLog)
                        .toggleStyle(.checkbox)
                }
                .font(.callout)
                .padding(.horizontal, 20)

                Text("You can launch FalconPulsar Menu Bar any time from the Applications folder, Launchpad, or Spotlight.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }

            Spacer()

            if !state.installSuccess {
                Button("View Install Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/falconpulsar-install.log"))
                }
                .font(.caption)
            }
        }
        .padding(30)
    }
}

struct ServiceRow: View {
    let name: String
    let url: String

    var body: some View {
        HStack {
            Text(name + ":")
                .frame(width: 100, alignment: .trailing)
                .font(.callout)
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.blue)
                .onTapGesture {
                    if let u = URL(string: url), url.hasPrefix("http") {
                        NSWorkspace.shared.open(u)
                    }
                }
        }
    }
}

// MARK: - Existing Install Page

struct ExistingInstallPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Existing Installation Detected")
                    .font(.title2.bold())
                Text("We found FalconPulsar already installed on this Mac. Choose how to handle it.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if state.detectingExisting {
                    HStack { ProgressView().scaleEffect(0.7); Text("Scanning…").font(.caption) }
                } else {
                    inventoryBox
                }

                Divider()

                Text("What would you like to do?").font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    actionRadio(.upgrade,
                                title: "Upgrade in place",
                                detail: "Pull latest images and restart. Keeps data, compose.yml, and .env.")
                    actionRadio(.reinstall,
                                title: "Reinstall (keep data)",
                                detail: "Recreate containers and rewrite stack files. Database preserved.")
                    actionRadio(.fresh,
                                title: "Fresh install — DELETE ALL DATA",
                                detail: "Stops everything, removes stack directory and database. Irreversible.",
                                destructive: true)
                }

                if state.installAction == .fresh && !state.existing.isEmpty {
                    Toggle(isOn: $state.freshConfirmed) {
                        Text("Yes, permanently delete my FalconPulsar database")
                            .foregroundColor(.red)
                    }
                }

                if !state.existing.images.isEmpty {
                    Toggle("Also remove cached Docker images",
                           isOn: $state.removeCachedImages)
                        .font(.callout)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { state.detectExistingInstall() }
    }

    @ViewBuilder
    private var inventoryBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.existing.stackDirExists {
                inventoryRow("Stack directory: ~/falconpulsar/\(state.existing.stackDirSize.isEmpty ? "" : " (\(state.existing.stackDirSize))")")
            }
            if state.existing.dataDirExists {
                inventoryRow("Database: ~/falconpulsar/data/\(state.existing.dataDirSize.isEmpty ? "" : " (\(state.existing.dataDirSize))")",
                             highlight: true)
            }
            if !state.existing.containers.isEmpty {
                inventoryRow("Containers: \(state.existing.containers.count) (\(state.existing.runningContainers.count) running)")
            }
            if !state.existing.images.isEmpty {
                inventoryRow("Cached images: \(state.existing.images.count)")
            }
            if state.existing.menuBarInstalled {
                inventoryRow("Menu bar app: installed")
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func inventoryRow(_ text: String, highlight: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 5))
                .foregroundColor(highlight ? .orange : .secondary)
            Text(text)
        }
    }

    @ViewBuilder
    private func actionRadio(_ action: InstallAction, title: String, detail: String, destructive: Bool = false) -> some View {
        Button(action: {
            state.installAction = action
            if action != .fresh { state.freshConfirmed = false }
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.installAction == action ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(state.installAction == action ? (destructive ? .red : .accentColor) : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                        .foregroundColor(destructive ? .red : .primary)
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
