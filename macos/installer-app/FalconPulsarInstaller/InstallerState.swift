import Foundation
import SwiftUI

enum InstallerPage: Int, CaseIterable {
    case welcome = 0
    case legal
    case registry
    case credentials
    case installing
    case conclusion
}

enum StepStatus {
    case pending, running, passed, failed, skipped
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

    // Environment detection
    @Published var dockerFound = false
    @Published var dockerRunning = false
    @Published var dockerPath = ""
    @Published var detecting = true

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
            DispatchQueue.main.async {
                self?.dockerPath = path ?? ""
                self?.dockerFound = path != nil
                self?.dockerRunning = running
                self?.detecting = false
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
        if let next = InstallerPage(rawValue: currentPage.rawValue + 1) {
            currentPage = next
        }
    }

    func prevPage() {
        if let prev = InstallerPage(rawValue: currentPage.rawValue - 1) {
            currentPage = prev
        }
    }
}
