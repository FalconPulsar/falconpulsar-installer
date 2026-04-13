import SwiftUI

struct InstallerView: View {
    @StateObject private var state = InstallerState()

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch state.currentPage {
                case .welcome: WelcomePage(state: state)
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

    func executeConclusionActions() {
        if state.installSuccess {
            if state.openWebUI {
                NSWorkspace.shared.open(URL(string: "http://localhost:8080")!)
            }
            if state.launchMenuBar {
                let appPath = "\(NSHomeDirectory())/Applications/FalconPulsar Menu Bar.app"
                if FileManager.default.fileExists(atPath: appPath) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                }
            }
            if state.viewLog {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/falconpulsar-install.log"))
            }
        }
        // Give a moment for actions to execute before quitting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Welcome Page

struct WelcomePage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(spacing: 16) {
            if let img = LogoData.image {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 80, height: 80)
            }
            Text("FalconPulsar")
                .font(.system(size: 28, weight: .bold))
            Text("Version 0.1.0")
                .foregroundColor(.secondary)
            Text("Self-host in 3 minutes. Your infrastructure, your data.")
                .font(.subheadline)

            Divider().padding(.horizontal, 40)

            if state.detecting {
                ProgressView("Detecting environment...")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(state.dockerFound ? "Docker: found" : "Docker: not found",
                          systemImage: state.dockerFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(state.dockerFound ? .green : .red)
                    Label(state.dockerRunning ? "Docker: running" : "Docker: not running",
                          systemImage: state.dockerRunning ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(state.dockerRunning ? .green : .orange)
                }
                .font(.callout)
            }

            Spacer()

            HStack {
                Text("falconpulsar.com").foregroundColor(.blue)
                    .onTapGesture { NSWorkspace.shared.open(URL(string: "https://falconpulsar.com")!) }
                Text("  |  ")
                    .foregroundColor(.secondary)
                Text("(c) 2026 FalconPulsar Contributors")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
        }
        .padding(30)
        .onAppear { state.detectEnvironment() }
    }
}

// MARK: - Legal Page

struct LegalPage: View {
    @ObservedObject var state: InstallerState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Legal Terms")
                .font(.title2.bold())

            Text("By installing FalconPulsar, you confirm you have read and agree to all four documents below. Click each link to open it in your browser.")
                .font(.callout)
                .foregroundColor(.secondary)

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

            Text("FalconPulsar images can be pulled from any OCI-compliant registry. Leave defaults if unsure.")
                .font(.callout)
                .foregroundColor(.secondary)

            Group {
                Text("Registry (hostname/namespace):")
                    .font(.callout.bold())
                TextField("falconpulsar", text: $state.registryUrl)
                    .textFieldStyle(.roundedBorder)

                Text("Username or org name (blank for public):")
                    .font(.callout.bold())
                TextField("", text: $state.registryUser)
                    .textFieldStyle(.roundedBorder)

                Text("Password or token:")
                    .font(.callout.bold())
                SecureField("", text: $state.registryPass)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Test Connection") {
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

            Toggle("Skip registry check", isOn: $state.registrySkip)
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

            Text("The password is used once to create the admin user, then exchanged for a service token. It is NOT stored on disk. Save it now.")
                .font(.callout)
                .foregroundColor(.secondary)

            Group {
                Text("Admin username:").font(.callout.bold())
                TextField("admin", text: $state.adminUser)
                    .textFieldStyle(.roundedBorder)

                Text("Admin password:").font(.callout.bold())
                SecureField("", text: $state.adminPass)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm password:").font(.callout.bold())
                SecureField("", text: $state.adminPassConfirm)
                    .textFieldStyle(.roundedBorder)
            }

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
                    Text("\(state.adminPass.count) characters")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            Text("Min 10 chars. Use uppercase, lowercase, numbers, and symbols.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Generate Strong Password") {
                    state.generatePassword()
                }
                if state.passwordGenerated {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.adminPass, forType: .string)
                    }
                }
            }

            if state.passwordGenerated {
                HStack {
                    Text("Generated:").font(.caption).foregroundColor(.secondary)
                    Text(state.generatedPassword)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
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
