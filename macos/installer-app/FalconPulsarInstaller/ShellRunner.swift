import Foundation

enum ShellRunner {
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = 10) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Include Docker Desktop's bin directory in PATH so credential
        // helpers (docker-credential-desktop) and CLI plugins are found.
        let extraPaths = "/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin"
        let fullCmd = "export PATH=\"\(extraPaths):$PATH\"; \(command)"
        process.arguments = ["-c", fullCmd]
        process.launchPath = "/bin/bash"

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    static func findDocker() -> String? {
        let paths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        let (output, code) = run("which docker 2>/dev/null")
        if code == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func isDockerRunning() -> Bool {
        guard let docker = findDocker() else { return false }
        let (_, code) = run("\(docker) info >/dev/null 2>&1")
        return code == 0
    }

    static func testRegistryAccess(registry: String, user: String, pass: String) -> (success: Bool, message: String) {
        guard let docker = findDocker() else {
            return (false, "Docker not found")
        }

        if !user.isEmpty && !pass.isEmpty {
            let host = registry.contains("/") ? String(registry.prefix(upTo: registry.firstIndex(of: "/")!)) : "docker.io"
            let (output, code) = run("echo '\(pass)' | \(docker) login \(host) --username '\(user)' --password-stdin 2>&1")
            if code != 0 {
                return (false, "Login rejected: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        let ref = "\(registry)/core:latest"
        let (_, code) = run("DOCKER_CLI_HINTS=false \(docker) manifest inspect \(ref) >/dev/null 2>&1")
        if code == 0 {
            return (true, "Connected. Images are pullable.")
        } else {
            return (false, "Cannot pull from \(registry). Check URL, credentials, and network.")
        }
    }
}
