import Foundation

enum ShellRunner {
    /// Run a full shell command string. Use this only for commands whose
    /// every component is hard-coded — never with user input.
    /// For anything that mixes user input with executables, use `runArgs`
    /// (no shell parsing, every argument passed via argv).
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

    /// SEC-010: argv-based exec. Every argument is passed verbatim to the
    /// child process — no shell parsing, no quoting required, safe with
    /// arbitrary user input (registry hosts, usernames, paths). Use this
    /// instead of `run(...)` whenever the command line includes anything
    /// the operator typed.
    ///
    /// If `stdin` is non-nil, it is fed to the child's stdin and the pipe
    /// is closed afterwards — used to pass secrets like a registry
    /// password to `docker login --password-stdin` without putting them
    /// on the command line (where they're visible in /proc/*/cmdline).
    @discardableResult
    static func runArgs(_ launchPath: String,
                        _ args: [String],
                        stdin: String? = nil,
                        env: [String: String]? = nil) -> (output: String, exitCode: Int32) {
        let process = Process()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        process.launchPath = launchPath
        process.arguments = args

        // Inherit current environment, then layer overrides.
        var fullEnv = ProcessInfo.processInfo.environment
        let extraPaths = "/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin"
        fullEnv["PATH"] = "\(extraPaths):\(fullEnv["PATH"] ?? "")"
        if let env = env { for (k, v) in env { fullEnv[k] = v } }
        process.environment = fullEnv

        var stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        }

        do {
            try process.run()
        } catch {
            return ("", -1)
        }

        if let p = stdinPipe, let data = stdin?.data(using: .utf8) {
            p.fileHandleForWriting.write(data)
            try? p.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
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
        // `which` doesn't take user input — safe to use the shell-form helper.
        let (output, code) = run("which docker 2>/dev/null")
        if code == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func isDockerRunning() -> Bool {
        guard let docker = findDocker() else { return false }
        // No user input — argv-style with a single docker subcommand.
        let (_, code) = runArgs(docker, ["info"])
        return code == 0
    }

    /// SEC-010: registry host / username / password no longer touch a shell
    /// command line. The password goes to the child's stdin (matches
    /// `docker login --password-stdin`'s contract); the username and
    /// registry host are argv-passed. This avoids:
    ///   * shell-metacharacter injection through the registry/user fields,
    ///   * the password being readable via `ps`/`/proc/<pid>/cmdline`.
    static func testRegistryAccess(registry: String, user: String, pass: String) -> (success: Bool, message: String) {
        guard let docker = findDocker() else {
            return (false, "Docker not found")
        }

        // Pull out the registry host (the portion before any '/'). Don't
        // pass anything we couldn't validate as a hostname-ish string to
        // docker login — at minimum reject obvious garbage. The regex is
        // intentionally permissive: dots, hyphens, alphanumerics, and
        // colon-port. Reject anything else so a path like "/etc/passwd"
        // or "$(id)" never reaches the child even via argv.
        let host = registry.contains("/")
            ? String(registry.prefix(upTo: registry.firstIndex(of: "/")!))
            : "docker.io"
        let hostRegex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._:-]+$"#)
        if hostRegex?.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) == nil {
            return (false, "Registry host contains unsupported characters: \(host)")
        }

        if !user.isEmpty && !pass.isEmpty {
            // docker login <host> --username <user> --password-stdin
            let (output, code) = runArgs(
                docker,
                ["login", host, "--username", user, "--password-stdin"],
                stdin: pass
            )
            if code != 0 {
                return (false, "Login rejected: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // For the manifest lookup we also have to be sure `registry` is
        // safe even as an argv string — same regex against the full
        // reference. Refuse anything weird up front rather than letting
        // docker try to interpret it.
        let refRegex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._:/-]+$"#)
        let refRange = NSRange(registry.startIndex..., in: registry)
        if refRegex?.firstMatch(in: registry, range: refRange) == nil {
            return (false, "Registry value contains unsupported characters")
        }
        let ref = "\(registry)/core:latest"
        let (_, code) = runArgs(
            docker,
            ["manifest", "inspect", ref],
            env: ["DOCKER_CLI_HINTS": "false"]
        )
        if code == 0 {
            return (true, "Connected. Images are pullable.")
        } else {
            return (false, "Cannot pull from \(registry). Check URL, credentials, and network.")
        }
    }
}
