import Foundation
import SwiftUI

enum InstallerPage: Int, CaseIterable {
    case welcome = 0
    case existing
    case legal
    case registry
    case credentials
    case installing
    case conclusion
}

enum StepStatus {
    case pending, running, passed, failed, skipped
}

enum InstallAction: String {
    case upgrade    // pull + recreate, preserves compose.yml/.env/data
    case reinstall  // rewrite stack files, preserves data
    case fresh      // delete everything and start over
}

struct ExistingInstall {
    var stackDirExists: Bool = false
    var stackDirSize: String = ""
    var containers: [String] = []      // names of FP containers (running or stopped)
    var runningContainers: [String] = []
    var images: [String] = []          // "repo:tag  size"
    var dataDirSize: String = ""
    var dataDirExists: Bool = false
    var menuBarInstalled: Bool = false

    var isEmpty: Bool {
        !stackDirExists && containers.isEmpty && images.isEmpty && !dataDirExists && !menuBarInstalled
    }
}

class InstallerState: ObservableObject {
    @Published var currentPage: InstallerPage = .welcome
    @Published var legalAccepted = false

    // Registry
    @Published var registryUrl = "falconpulsar"
    @Published var registryUser = ""
    @Published var registryPass = ""
    @Published var registryTestResult = ""
    @Published var registryTestOk = false
    @Published var registrySkip = false

    // Credentials
    @Published var adminUser = "admin"
    @Published var adminPass = ""
    @Published var adminPassConfirm = ""
    @Published var passwordGenerated = false

    // FalconPulsar Gateway (enabled by default — it powers Workspace
    // commands and standing watches, not just the AI assistant; AI models
    // remain optional and are configured later in ConfigHub).
    @Published var aiGatewayEnabled = true

    // Front-door HTTPS declaration (enabled by default — recommended).
    // Drives the Secure flag and `__Host-` prefix on session cookies.
    // Operators on HTTP-only trusted LANs uncheck explicitly. See
    // linux/install.sh's `prompt_transport_mode` for the equivalent
    // CLI prompt.
    @Published var cookieSecure = true

    // Environment detection
    @Published var dockerFound = false
    @Published var dockerRunning = false
    @Published var dockerPath = ""
    @Published var composeV2 = false
    @Published var detecting = true
    @Published var runtimeName = ""

    // Existing install detection
    @Published var existing: ExistingInstall = ExistingInstall()
    @Published var detectingExisting = false
    @Published var installAction: InstallAction = .fresh
    @Published var removeCachedImages = false
    @Published var freshConfirmed = false

    // Install progress
    @Published var steps: [(name: String, status: StepStatus)] = [
        ("Pre-flight checks", .pending),
        ("Container runtime", .pending),
        ("Registry access", .pending),
        ("Create stack directory", .pending),
        ("Pull container images", .pending),
        ("Start services", .pending),
        ("Verify health", .pending)
    ]
    @Published var installLog = ""
    @Published var installSuccess = false
    @Published var installError = ""

    // Conclusion
    @Published var generatedPassword = ""
    @Published var openWebUI = true
    @Published var launchMenuBar = true
    @Published var viewLog = false

    func detectEnvironment() {
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let path = ShellRunner.findDocker()
            let running = ShellRunner.isDockerRunning()
            var compose = false
            var runtime = ""
            if let p = path, running {
                let (out, code) = ShellRunner.run("\(p) compose version 2>&1")
                compose = (code == 0)
                let (ctx, _) = ShellRunner.run("\(p) context show 2>/dev/null")
                runtime = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async {
                self?.dockerPath = path ?? ""
                self?.dockerFound = path != nil
                self?.dockerRunning = running
                self?.composeV2 = compose
                self?.runtimeName = runtime
                self?.detecting = false
            }
        }
    }

    var prerequisitesOk: Bool {
        dockerFound && dockerRunning && composeV2
    }

    func detectExistingInstall() {
        detectingExisting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = ExistingInstall()
            let home = NSHomeDirectory()
            let fm = FileManager.default

            let stackDir = "\(home)/falconpulsar"
            if fm.fileExists(atPath: stackDir) {
                found.stackDirExists = true
                let (sz, _) = ShellRunner.run("/usr/bin/du -sh '\(stackDir)' 2>/dev/null | /usr/bin/awk '{print $1}'")
                found.stackDirSize = sz.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let dataDir = "\(stackDir)/data"
            if fm.fileExists(atPath: dataDir) {
                found.dataDirExists = true
                let (sz, _) = ShellRunner.run("/usr/bin/du -sh '\(dataDir)' 2>/dev/null | /usr/bin/awk '{print $1}'")
                found.dataDirSize = sz.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let docker = ShellRunner.findDocker() {
                let (psAll, _) = ShellRunner.run("\(docker) ps -a --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null")
                found.containers = psAll.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

                let (psRun, _) = ShellRunner.run("\(docker) ps --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null")
                found.runningContainers = psRun.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

                let (imgs, _) = ShellRunner.run("\(docker) images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null")
                found.images = imgs.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }

            if fm.fileExists(atPath: "/Applications/FalconPulsar Menu Bar.app") {
                found.menuBarInstalled = true
            }

            DispatchQueue.main.async {
                self?.existing = found
                self?.detectingExisting = false
                // Default action: upgrade if stack dir exists, fresh otherwise
                if found.stackDirExists || !found.containers.isEmpty {
                    self?.installAction = .upgrade
                } else {
                    self?.installAction = .fresh
                }
            }
        }
    }

    var passwordStrength: String {
        let p = adminPass
        if p.count < 10 { return "Weak" }
        var classes = 0
        if p.range(of: "[A-Z]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[a-z]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[0-9]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil { classes += 1 }
        if p.count >= 12 && classes >= 3 { return "Strong" }
        if classes >= 2 { return "Medium" }
        return "Weak"
    }

    var strengthColor: Color {
        switch passwordStrength {
        case "Strong": return .green
        case "Medium": return .orange
        default: return .red
        }
    }

    func generatePassword() {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%&*-_=+"
        adminPass = String((0..<20).map { _ in chars.randomElement()! })
        adminPassConfirm = adminPass
        passwordGenerated = true
        generatedPassword = adminPass
    }

    var canProceedFromCredentials: Bool {
        adminUser.count >= 1 &&
        adminPass.count >= 10 &&
        adminPass == adminPassConfirm
    }

    func nextPage() {
        guard let next = InstallerPage(rawValue: currentPage.rawValue + 1) else { return }
        if next == .existing && existing.isEmpty {
            currentPage = InstallerPage(rawValue: next.rawValue + 1) ?? next
        } else {
            currentPage = next
        }
    }

    func prevPage() {
        guard let prev = InstallerPage(rawValue: currentPage.rawValue - 1) else { return }
        if prev == .existing && existing.isEmpty {
            currentPage = InstallerPage(rawValue: prev.rawValue - 1) ?? prev
        } else {
            currentPage = prev
        }
    }

    var canProceedFromExisting: Bool {
        if installAction == .fresh && !existing.isEmpty {
            return freshConfirmed
        }
        return true
    }
}
