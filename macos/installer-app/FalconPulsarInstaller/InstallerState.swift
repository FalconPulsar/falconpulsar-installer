// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import Foundation
import SwiftUI

enum InstallerPage: Int, CaseIterable {
    case welcome = 0
    case existing
    case legal
    case registry
    case options
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
    // FP_AI_ENGINE_ENABLED parsed from the surviving .env (nil when the
    // file or key is absent). Used to make the AI Engine checkbox sticky
    // across reinstalls/upgrades.
    var envAIEngineEnabled: Bool? = nil
    // FP_COPILOT_ENABLED parsed from the surviving .env (nil when the file or
    // key is absent). Makes the Command Center checkbox sticky across
    // reinstalls/upgrades.
    var envCopilotEnabled: Bool? = nil

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

    // Front-door HTTPS declaration (enabled by default — recommended).
    // Drives the Secure flag and `__Host-` prefix on session cookies.
    // Operators on HTTP-only trusted LANs uncheck explicitly. See
    // linux/install.sh's `prompt_transport_mode` for the equivalent
    // CLI prompt.
    @Published var cookieSecure = true

    // Optional AI Engine (agent runtime). Off by default — the checkbox on
    // the Options page opts in, which install.sh turns into
    // FP_AI_ENGINE_ENABLED=true / COMPOSE_PROFILES=engine. Sticky on
    // reinstall: detectExistingInstall seeds it from the surviving .env
    // unless the user has already toggled it this session.
    @Published var aiEngineEnabled = false
    var aiEngineUserSet = false

    // Optional Command Center (ops workspace). Off by default — the
    // checkbox on the Options page opts in, which install.sh turns into
    // FP_COPILOT_ENABLED=true / COMPOSE_PROFILES=copilot. Sticky on reinstall:
    // seeded from the surviving .env unless toggled this session.
    @Published var copilotEnabled = false
    var copilotUserSet = false

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
    /// True once detection has actually answered.
    ///
    /// `existing.isEmpty` cannot carry this on its own: it is equally true
    /// before we have looked and after we have looked and found nothing. The
    /// page-skip logic used it anyway, so an operator who clicked Continue
    /// faster than `du` could walk a 34GB stack directory was shown the
    /// fresh-install path — registry, options, credentials — on a machine
    /// with five running containers. Going Back then revealed the page,
    /// because by then detection had finished. That asymmetry is the tell.
    @Published var existingDetectionDone = false
    @Published var installAction: InstallAction = .fresh
    /// Set the moment the operator picks an option on the existing-install
    /// page. Detection now finishes AFTER that page can be on screen, so
    /// without this the slow half could overwrite a deliberate choice —
    /// the same class of bug as the skip it is fixing.
    var installActionUserSet = false
    @Published var removeCachedImages = false
    @Published var freshConfirmed = false
    // True when the runner's upgrade fast-path can handle this stack
    // (compose.yml present, AI-Gateway already provisioned). When it can,
    // "Upgrade in place" skips the rest of the wizard: the fast-path never
    // uses the legal/registry/options/credentials answers — it pulls and
    // restarts with the surviving .env, exactly like the tray's Apply Now.
    // Legacy stacks (no gateway token/service) still need the full wizard,
    // because migrating them mints a gateway token with admin credentials.
    @Published var upgradeFastPathViable = false

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

            // ── Phase 1: what is knowable INSTANTLY ────────────────────
            // Whether a stack exists is a filesystem question and answers in
            // microseconds. Sizes are a `du` walk over tens of gigabytes, and
            // the docker lists cost a daemon round-trip each. Publishing the
            // cheap facts first is what lets the page appear before the
            // operator can click past it; the expensive detail arrives after
            // and only enriches what is already on screen.
            let stackDir = "\(home)/falconpulsar"
            found.stackDirExists = fm.fileExists(atPath: stackDir)

            let dataDir = "\(stackDir)/data"
            found.dataDirExists = fm.fileExists(atPath: dataDir)

            // Sticky AI Engine opt-in: read FP_AI_ENGINE_ENABLED from the
            // surviving .env so a reinstall defaults the checkbox to what
            // the operator chose last time. Last occurrence wins, matching
            // docker compose's env-file semantics (and install.sh's own
            // fp_seed_from_existing_env).
            if let envText = try? String(contentsOfFile: "\(stackDir)/.env", encoding: .utf8) {
                let key = "FP_AI_ENGINE_ENABLED="
                if let line = envText.split(separator: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .last(where: { $0.hasPrefix(key) }) {
                    found.envAIEngineEnabled = (String(line.dropFirst(key.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "true")
                }
                let copKey = "FP_COPILOT_ENABLED="
                if let copLine = envText.split(separator: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .last(where: { $0.hasPrefix(copKey) }) {
                    found.envCopilotEnabled = (String(copLine.dropFirst(copKey.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "true")
                }
            }

            // Everything the DECISION needs is now known. Publish it, so the
            // wizard can route correctly even if the operator is fast.
            let phase1 = found
            DispatchQueue.main.async {
                self?.existing = phase1
                self?.existingDetectionDone = true
                if phase1.stackDirExists {
                    self?.installAction = .upgrade
                }
                if let sticky = phase1.envAIEngineEnabled, self?.aiEngineUserSet != true {
                    self?.aiEngineEnabled = sticky
                }
                if let sticky = phase1.envCopilotEnabled, self?.copilotUserSet != true {
                    self?.copilotEnabled = sticky
                }
            }

            // ── Phase 2: the slow detail (sizes + docker inventory) ────────
            if fm.fileExists(atPath: stackDir) {
                let (sz, _) = ShellRunner.run("/usr/bin/du -sh '\(stackDir)' 2>/dev/null | /usr/bin/awk '{print $1}'")
                found.stackDirSize = sz.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if fm.fileExists(atPath: dataDir) {
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

            // Upgrade fast-path viability — the same three checks the runner
            // makes (compose.yml intact, gateway token in .env, ai-gateway
            // service in compose). Computed once here so the wizard can skip
            // the remaining pages when "Upgrade in place" can truly run
            // without them.
            var fastPathOk = fm.fileExists(atPath: "\(stackDir)/compose.yml")
            if fastPathOk {
                let envText = (try? String(contentsOfFile: "\(stackDir)/.env", encoding: .utf8)) ?? ""
                let composeText = (try? String(contentsOfFile: "\(stackDir)/compose.yml", encoding: .utf8)) ?? ""
                let hasApiKey = envText.split(separator: "\n")
                    .contains { $0.hasPrefix("FP_API_KEY=") && $0.count > "FP_API_KEY=".count }
                let hasGatewayService = composeText.split(separator: "\n")
                    .contains { $0.trimmingCharacters(in: .whitespaces) == "ai-gateway:" }
                fastPathOk = hasApiKey && hasGatewayService
            }

            DispatchQueue.main.async {
                self?.existing = found
                self?.detectingExisting = false
                self?.existingDetectionDone = true
                self?.upgradeFastPathViable = fastPathOk
                // Default action: upgrade when anything survives. Only ever
                // PROMOTES, and never over a choice the operator has already
                // made — this block now runs while the page is on screen, so
                // demoting to .fresh here could silently retarget an upgrade
                // at a stack the operator meant to keep.
                if self?.installActionUserSet != true,
                   found.stackDirExists || !found.containers.isEmpty {
                    self?.installAction = .upgrade
                }
                // Seed the AI Engine checkbox from the surviving .env, but
                // never clobber a choice the user already made this session
                // (detection re-runs when navigating back to earlier pages).
                if let sticky = found.envAIEngineEnabled, self?.aiEngineUserSet != true {
                    self?.aiEngineEnabled = sticky
                }
                if let sticky = found.envCopilotEnabled, self?.copilotUserSet != true {
                    self?.copilotEnabled = sticky
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

    /// May the "Existing Installation Detected" page be skipped?
    ///
    /// ONLY when detection has finished AND found nothing. While it is still
    /// running the answer is no — the page shows its own spinner, which is
    /// the honest thing to display when we do not yet know. Skipping on an
    /// unanswered question sent an operator with a 34GB stack down the
    /// fresh-install path.
    private var mayShushExistingPage: Bool {
        existingDetectionDone && existing.isEmpty
    }

    func nextPage() {
        guard let next = InstallerPage(rawValue: currentPage.rawValue + 1) else { return }
        if next == .existing && mayShushExistingPage {
            currentPage = InstallerPage(rawValue: next.rawValue + 1) ?? next
        } else {
            currentPage = next
        }
    }

    func prevPage() {
        guard let prev = InstallerPage(rawValue: currentPage.rawValue - 1) else { return }
        if prev == .existing && mayShushExistingPage {
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
