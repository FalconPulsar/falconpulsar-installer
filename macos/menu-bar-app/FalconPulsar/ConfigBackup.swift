import Foundation
import AppKit
import CryptoKit

// =============================================================================
//  FalconPulsar configuration backup format (.fpconfig)
//
//  Authoritative spec lives in console/internal/configbackup/backup.go.
//  The macOS/Windows/Linux implementations all produce + consume the same
//  binary envelope below; the v2 payload also includes asset-types, series
//  (with engineering+alarms inline), relationships, and annotations, and the
//  v3 payload adds the admin config-bundle (users/roles/tokens/layouts with
//  secrets).
// =============================================================================
//  Outer framing (binary):
//    [0..3]   Magic = "FPCF"                 (4 bytes)
//    [4]      Format version                 (1 byte; writes: 3, accepts: 1, 2, 3)
//    [5..20]  PBKDF2 salt                    (16 bytes)
//    [21..32] AES-GCM nonce/IV               (12 bytes)
//    [33..]   AES-256-GCM ciphertext of the zip payload
//    [last 16 bytes are the GCM auth tag, combined into Sealed by CryptoKit]
//
//  Key derivation:
//    key = PBKDF2-HMAC-SHA256(
//            password = "<admin_user>:<admin_password>",
//            salt     = <salt>,
//            iter     = 100_000,
//            keyLen   = 32)
//
//  Payload (zip archive):
//    manifest.json                 ← format + FP version + timestamp + source host
//    files/compose.yml
//    files/.env                    ← may contain secrets (encrypted)
//    files/gateway.yaml
//    api/roles.json                ← GET /api/v1/roles
//    api/users.json                ← GET /api/v1/users
//    api/asset-types.json          ← GET /api/v1/asset-types       (NEW in v2)
//    api/assets.json               ← GET /api/v1/assets
//    api/datasources.json          ← GET /api/v1/datasources
//    api/series.json               ← GET /api/v1/series?include_engineering=true&limit=100000   (NEW in v2)
//    api/mappings.json             ← GET /api/v1/mappings
//    api/relationships.json        ← GET /api/v1/relationships     (NEW in v2)
//    api/annotations.json          ← GET /api/v1/annotations       (NEW in v2)
//    api/config-bundle.json        ← GET /api/v1/admin/config-bundle (NEW in v3)
//                                     the complete-server secrets: user password
//                                     hashes+salts, MFA secrets, API-token
//                                     records, roles, and layout/favorite/label/
//                                     preference KV — applied first on import.
// =============================================================================
//  Format version compatibility:
//    v1: 5 sections (users, roles, datasources, mappings, assets). Import
//        still works.
//    v2: adds asset-types, series, relationships, annotations. Imports of v1
//        files succeed (the missing sections are skipped silently).
//    v3: adds config-bundle.json. On import it is applied first (restoring
//        users/roles/tokens/layouts verbatim, with secrets); the users+roles
//        REST sections are then skipped. A v3 file on a v1/v2-only client is
//        rejected at the version-byte check.
// =============================================================================

enum ConfigBackup {
    static let magic: [UInt8] = [0x46, 0x50, 0x43, 0x46]  // "FPCF"
    /// Version this build *writes*. Older versions are still accepted on read.
    ///
    /// v3 adds api/config-bundle.json — the admin-only "complete server"
    /// bundle from GET /api/v1/admin/config-bundle: user password hashes +
    /// salts, MFA secrets, API-token records, roles, and the canvas
    /// layout/favorite/label/preference KV. It is the ONLY source of the
    /// secrets a real "restore a server" needs, so a v3 restore rebuilds a
    /// server with the SAME passwords, tokens, MFA, and dashboards. The
    /// bundle is applied first on import; when present, the users+roles REST
    /// sections are skipped (the bundle already restored them verbatim, with
    /// secrets).
    static let formatVersion: UInt8 = 3
    /// Oldest format this build can decrypt and parse.
    static let minReadableFormatVersion: UInt8 = 1
    static let pbkdf2Iterations: UInt32 = 100_000
    static let saltLength = 16
    static let nonceLength = 12
    static let homeDir: String = "\(NSHomeDirectory())/falconpulsar"

    /// Core's base URL. The REST port comes from the stack's .env
    /// (FP_REST_PORT) so port-remapped installs still reach Core; 7433 is
    /// only the installer default, used when .env is missing or doesn't
    /// set the key.
    static var coreBaseURL: String { "http://localhost:\(envValue("FP_REST_PORT") ?? "7433")" }

    /// Reads one value out of the stack's .env. Returns nil when the file or
    /// key is missing. Last occurrence wins, matching docker compose's own
    /// env-file semantics (mirrors AppDelegate.envValue).
    private static func envValue(_ key: String) -> String? {
        guard let content = try? String(contentsOfFile: "\(homeDir)/.env", encoding: .utf8) else {
            return nil
        }
        var value: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            let v = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { value = v }
        }
        return value
    }

    struct AdminCredentials {
        let username: String
        let password: String
        let token: String
    }

    enum BackupError: Error, LocalizedError {
        case loginFailed(String)
        case notAdmin
        case apiError(String)
        case fileError(String)
        case encryptError(String)
        case decryptError(String)
        case zipError(String)
        case invalidFile(String)
        case containersNotRunning

        var errorDescription: String? {
            switch self {
            case .loginFailed(let m):   return "Login failed: \(m)"
            case .notAdmin:             return "This account is not an administrator. Ask your administrator for help."
            case .apiError(let m):      return "API error: \(m)"
            case .fileError(let m):     return "File error: \(m)"
            case .encryptError(let m):  return "Encryption error: \(m)"
            case .decryptError(let m):  return "Decryption error — wrong admin credentials or corrupted file: \(m)"
            case .zipError(let m):      return "Archive error: \(m)"
            case .invalidFile(let m):   return "Not a FalconPulsar backup file: \(m)"
            case .containersNotRunning: return "FalconPulsar Core must be running to export or import configuration."
            }
        }
    }

    // MARK: - Authentication + admin verification

    /// Validates credentials against Core (coreBaseURL) and verifies
    /// the user has the admin role. Returns an AdminCredentials with the auth
    /// token on success; throws BackupError otherwise.
    static func authenticateAsAdmin(username: String, password: String) throws -> AdminCredentials {
        let loginURL = URL(string: "\(coreBaseURL)/api/v1/auth/login")!
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password
        ])
        // Remap login-endpoint failures to actionable messages. 401 = wrong credentials
        // (the most common case); other statuses mean Core is up but unhappy; a thrown
        // URLError typically means Core is not reachable at all.
        let data: Data
        let token: String?
        do {
            (data, token) = try syncRequest(req)
        } catch let BackupError.apiError(msg) {
            if msg == "HTTP 401" {
                throw BackupError.loginFailed("Incorrect username or password.")
            }
            if msg == "HTTP 403" {
                throw BackupError.loginFailed("Access denied.")
            }
            throw BackupError.loginFailed(
                "Cannot reach FalconPulsar Core (\(msg)). Check that the stack is running.")
        } catch {
            throw BackupError.loginFailed(
                "Cannot reach FalconPulsar Core at \(coreBaseURL).")
        }
        guard let tokenString = token ?? (try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any])?["token"] as? String,
              !tokenString.isEmpty else {
            throw BackupError.loginFailed("No token returned by server.")
        }

        // Verify role
        let meURL = URL(string: "\(coreBaseURL)/api/v1/auth/me")!
        var meReq = URLRequest(url: meURL)
        meReq.addValue("Bearer \(tokenString)", forHTTPHeaderField: "Authorization")
        let (meData, _) = try syncRequest(meReq)
        guard let meJson = try? JSONSerialization.jsonObject(with: meData) as? [String: Any],
              let role = meJson["role"] as? String ?? (meJson["roles"] as? [String])?.first else {
            throw BackupError.apiError("could not read user role")
        }
        guard role.lowercased() == "admin" else {
            throw BackupError.notAdmin
        }

        return AdminCredentials(username: username, password: password, token: tokenString)
    }

    private static func syncRequest(_ req: URLRequest) throws -> (Data, String?) {
        var result: Data?
        var error: Error?
        var token: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, err in
            if let err = err { error = err }
            else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                error = BackupError.apiError("HTTP \(http.statusCode)")
            }
            else {
                result = data ?? Data()
                if let d = data,
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    token = j["token"] as? String
                }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if let e = error { throw e }
        return (result ?? Data(), token)
    }

    /// Number of model items the last importBackup could not restore (a
    /// datasource/mapping/etc. the server rejected). Reset at the start of each
    /// import; read by the caller to warn instead of reporting a silent success.
    static var lastImportErrorCount = 0

    /// Fire a request and return the HTTP status (0 on transport failure).
    /// Used by import to detect a rejected item without the throw/try? dance —
    /// previously every failure was swallowed by `_ = try? syncRequest(req)`.
    private static func requestStatus(_ req: URLRequest) -> Int {
        var status = 0
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return status
    }

    /// True when the status is a failure worth surfacing (not 2xx, not a 409
    /// "already exists" which restore treats as a benign skip).
    private static func isImportFailure(_ status: Int) -> Bool {
        return (status < 200 || status >= 300) && status != 409
    }

    // MARK: - PBKDF2 + AES-GCM

    static func deriveKey(username: String, password: String, salt: Data) throws -> SymmetricKey {
        let passphrase = "\(username):\(password)"
        guard var passData = passphrase.data(using: .utf8) else {
            throw BackupError.encryptError("invalid password encoding")
        }
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32)
                }
            }
        }
        // Best-effort wipe of the cleartext passphrase buffer. Swift's
        // String storage is reference-counted and we can't reach it, but
        // the Data we built is ours to clear.
        passData.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                memset_s(base, ptr.count, 0, ptr.count)
            }
        }
        guard status == 0 else {
            throw BackupError.encryptError("PBKDF2 failed (\(status))")
        }
        return SymmetricKey(data: derived)
    }

    static func encrypt(_ plaintext: Data, username: String, password: String) throws -> Data {
        var salt = Data(count: saltLength)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        let key = try deriveKey(username: username, password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let nonceData = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data? else {
            throw BackupError.encryptError("nonce encoding failed")
        }
        var out = Data()
        out.append(contentsOf: magic)
        out.append(formatVersion)
        out.append(salt)
        out.append(nonceData)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    static func decrypt(_ data: Data, username: String, password: String) throws -> Data {
        guard data.count > 4 + 1 + saltLength + nonceLength + 16 else {
            throw BackupError.invalidFile("file too short")
        }
        // Magic
        guard Array(data.prefix(4)) == magic else {
            throw BackupError.invalidFile("magic bytes mismatch")
        }
        // Accept any version we know how to read. The version byte is
        // authenticated by the GCM tag below, so a tampered value would fail
        // decryption anyway.
        let v = data[4]
        guard v >= Self.minReadableFormatVersion && v <= Self.formatVersion else {
            throw BackupError.invalidFile(
                "unsupported format version \(v) (this client supports v\(Self.minReadableFormatVersion)–v\(Self.formatVersion))")
        }
        let salt  = data.subdata(in: 5..<5+saltLength)
        let nonce = data.subdata(in: 5+saltLength..<5+saltLength+nonceLength)
        let bodyStart = 5 + saltLength + nonceLength
        let tagStart = data.count - 16
        let ciphertext = data.subdata(in: bodyStart..<tagStart)
        let tag = data.subdata(in: tagStart..<data.count)

        let key = try deriveKey(username: username, password: password, salt: salt)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealed, using: key)
    }

    // MARK: - Zip via system `/usr/bin/zip` / `/usr/bin/unzip`

    static func zipDirectory(at path: String, to zipPath: String) throws {
        let task = Process()
        task.launchPath = "/usr/bin/zip"
        task.arguments = ["-r", "-q", zipPath, "."]
        task.currentDirectoryPath = path
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw BackupError.zipError("zip exited \(task.terminationStatus)")
        }
    }

    static func unzipArchive(at zipPath: String, to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let task = Process()
        task.launchPath = "/usr/bin/unzip"
        task.arguments = ["-q", "-o", zipPath, "-d", directory]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw BackupError.zipError("unzip exited \(task.terminationStatus)")
        }
    }

    // MARK: - Export

    static func export(to outputPath: String, creds: AdminCredentials) throws {
        let fm = FileManager.default
        let workDir = NSTemporaryDirectory() + "fpconfig-\(UUID().uuidString)"
        try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: workDir) }

        // Files
        let filesDir = "\(workDir)/files"
        try fm.createDirectory(atPath: filesDir, withIntermediateDirectories: true)
        for name in ["compose.yml", ".env", "gateway.yaml"] {
            let src = "\(homeDir)/\(name)"
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: "\(filesDir)/\(name)")
            }
        }

        // API harvest. The list mirrors backup.go in console/. Each section
        // is fetched via harvestPaginated() which walks has_more / next_offset
        // until exhaustion — this is required for /api/v1/series, which the
        // Core server hard-caps at output_max_rows (default 1000) per page
        // regardless of any ?limit= the client asks for. Without pagination
        // large installations were silently truncated at 1000 series.
        let apiDir = "\(workDir)/api"
        try fm.createDirectory(atPath: apiDir, withIntermediateDirectories: true)
        let sections: [(file: String, path: String, key: String)] = [
            ("roles.json",         "/api/v1/roles",                                "roles"),
            ("users.json",         "/api/v1/users",                                "users"),
            ("asset-types.json",   "/api/v1/asset-types",                          "asset_types"),
            ("assets.json",        "/api/v1/assets",                               "assets"),
            ("datasources.json",   "/api/v1/datasources",                          "datasources"),
            ("series.json",        "/api/v1/series?include_engineering=true",      "series"),
            ("mappings.json",      "/api/v1/mappings",                             "mappings"),
            ("relationships.json", "/api/v1/relationships",                        "relationships"),
            ("annotations.json",   "/api/v1/annotations",                          "annotations"),
        ]
        for sec in sections {
            if let data = Self.harvestPaginated(path: sec.path, sectionKey: sec.key, token: creds.token) {
                fm.createFile(atPath: "\(apiDir)/\(sec.file)", contents: data)
            } else {
                // Empty stub so import can run with what we got. Matches the
                // Go console behaviour.
                let stub = "{\"\(sec.key)\":[]}".data(using: .utf8) ?? Data()
                fm.createFile(atPath: "\(apiDir)/\(sec.file)", contents: stub)
            }
        }

        // v3: the complete server bundle — password hashes, MFA secrets, API
        // tokens, roles, layouts, favorites, labels, preferences. This is the
        // ONLY source of the secrets a real "restore a server" needs; the whole
        // backup is AES-encrypted so these never touch disk in the clear. Fetch
        // it last, after the plain REST sections. A server too old to expose
        // the endpoint (404) simply yields no bundle and the backup degrades
        // to v2 behaviour on import — so any non-2xx / network error is skipped
        // silently. The client treats the response as an opaque blob; it moves
        // the bytes verbatim (GET body → zip → POST body) without parsing.
        let bundleURL = URL(string: "\(coreBaseURL)/api/v1/admin/config-bundle")!
        var bundleReq = URLRequest(url: bundleURL)
        bundleReq.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        if let (bundle, _) = try? syncRequest(bundleReq), !bundle.isEmpty {
            fm.createFile(atPath: "\(apiDir)/config-bundle.json", contents: bundle)
        }

        // Manifest
        let hostName = Host.current().localizedName ?? "unknown"
        let df = ISO8601DateFormatter()
        let manifest: [String: Any] = [
            "format_version": Int(formatVersion),
            "falconpulsar_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
            "exported_at": df.string(from: Date()),
            "source_host": hostName,
            "source_platform": "macOS"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        fm.createFile(atPath: "\(workDir)/manifest.json", contents: manifestData)

        // Zip
        let zipPath = NSTemporaryDirectory() + "fpconfig-\(UUID().uuidString).zip"
        defer { try? fm.removeItem(atPath: zipPath) }
        try zipDirectory(at: workDir, to: zipPath)

        let plain = try Data(contentsOf: URL(fileURLWithPath: zipPath))
        let encrypted = try encrypt(plain, username: creds.username, password: creds.password)
        try encrypted.write(to: URL(fileURLWithPath: outputPath))
    }

    // MARK: - Import

    static func importBackup(from inputPath: String, creds: AdminCredentials) throws {
        lastImportErrorCount = 0
        let fm = FileManager.default
        let encrypted = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let plain = try decrypt(encrypted, username: creds.username, password: creds.password)

        let tmpZip = NSTemporaryDirectory() + "fpconfig-in-\(UUID().uuidString).zip"
        try plain.write(to: URL(fileURLWithPath: tmpZip))
        defer { try? fm.removeItem(atPath: tmpZip) }

        let workDir = NSTemporaryDirectory() + "fpconfig-in-\(UUID().uuidString)"
        try unzipArchive(at: tmpZip, to: workDir)
        defer { try? fm.removeItem(atPath: workDir) }

        // Restore config files
        let filesDir = "\(workDir)/files"
        if fm.fileExists(atPath: filesDir) {
            // Preserve the target host's machine-specific .env values (absolute
            // paths + uid/gid) — never transplant the backup's. A backup taken
            // on another host carries ITS FP_DATA_DIR etc.; restoring those
            // verbatim repoints core's bind mount at a path that doesn't exist
            // here -> Docker mounts an empty dir -> core crash-loops on first
            // run. Capture BEFORE the backup's .env overwrites the current one.
            let preservedEnv = Self.readEnvValues(keys: Self.machineSpecificEnvKeys)
            for name in ["compose.yml", ".env", "gateway.yaml"] {
                let src = "\(filesDir)/\(name)"
                let dst = "\(homeDir)/\(name)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try fm.copyItem(atPath: src, toPath: dst)
                }
            }
            sanitizeRestoredEnv(preserved: preservedEnv)
        }

        // Push API data back in dependency order. v2-aware: handles the new
        // sections (asset-types, series, relationships, annotations) if
        // present in the zip. Strips server-assigned fields before POSTing
        // so the target server mints fresh IDs by natural key.
        //
        // For each section we try the keyed-by-entity convention first
        // ({"users":[...]}, {"series":[...]}), fall back to bare-array,
        // then a generic {"items":[...]} wrapper.
        let apiDir = "\(workDir)/api"

        // v3: apply the complete server bundle FIRST — it restores users (with
        // their password hashes + MFA), roles, API tokens, and the canvas
        // layout/favorite/label/preference KV verbatim via the admin endpoint.
        // The bytes are POSTed opaquely (no parsing/transform). When it applies,
        // the users+roles REST sections below are skipped so a verbatim,
        // password-preserving restore isn't overwritten by the password-less
        // REST create path (which would only add duplicates / 409s).
        var bundleApplied = false
        let bundleFilePath = "\(apiDir)/config-bundle.json"
        if fm.fileExists(atPath: bundleFilePath),
           let bundleData = try? Data(contentsOf: URL(fileURLWithPath: bundleFilePath)) {
            let bundleURL = URL(string: "\(coreBaseURL)/api/v1/admin/config-bundle")!
            var req = URLRequest(url: bundleURL)
            req.httpMethod = "POST"
            req.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bundleData
            if (try? syncRequest(req)) != nil {
                bundleApplied = true
                NSLog("FalconPulsar: config-bundle restored (users w/ passwords, MFA, API tokens, roles, layouts) — skipping REST users+roles sections")
            } else {
                NSLog("FalconPulsar: config-bundle POST FAILED — users/passwords/tokens/layouts NOT restored; falling back to REST users+roles")
            }
        }

        let sections: [(file: String, path: String, key: String)] = [
            ("roles.json",         "/api/v1/roles",         "roles"),
            ("asset-types.json",   "/api/v1/asset-types",   "asset_types"),
            ("users.json",         "/api/v1/users",         "users"),
            ("datasources.json",   "/api/v1/datasources",   "datasources"),
            ("assets.json",        "/api/v1/assets",        "assets"),
            ("series.json",        "/api/v1/series",        "series"),
            ("mappings.json",      "/api/v1/mappings",      "mappings"),
            ("relationships.json", "/api/v1/relationships", "relationships"),
            ("annotations.json",   "/api/v1/annotations",   "annotations"),
        ]
        for sec in sections {
            // When the v3 bundle applied, users + roles were restored verbatim
            // (with password hashes + secrets). Re-running the REST create path
            // for them would only add password-less duplicates / 409s.
            if bundleApplied && (sec.key == "users" || sec.key == "roles") {
                continue
            }
            let filePath = "\(apiDir)/\(sec.file)"
            guard fm.fileExists(atPath: filePath),
                  let json = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }
            let items = Self.extractItems(from: json, sectionKey: sec.key)
            // Series restore their FULL config in one bulk call: POST
            // /api/v1/series/bulk resolves the asset by path AND applies the
            // engineering limits + alarm thresholds, unlike the per-item POST
            // /api/v1/series (which requires an "asset" field the export never
            // emits and drops the limits/thresholds entirely).
            if sec.key == "series" {
                Self.importSeriesBulk(items: items, creds: creds, coreBaseURL: coreBaseURL)
                continue
            }
            for raw in items {
                let item = Self.stripServerIDs(raw)
                let url = URL(string: "\(coreBaseURL)\(sec.path)")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
                req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: item)
                // Count (don't swallow) a server rejection so the caller can warn
                // — a rejected datasource/mapping means dead series after restore.
                if Self.isImportFailure(Self.requestStatus(req)) { Self.lastImportErrorCount += 1 }
            }
        }
    }

    /// .env keys tied to the HOST the stack runs on — absolute host paths and
    /// the host uid/gid — rather than the logical configuration. On restore
    /// they must keep the TARGET host's values, never the backup's, or a
    /// cross-host restore repoints core's bind mount at a non-existent path
    /// and the container crash-loops. Everything else in .env (secrets, ports,
    /// flags, admin user) is portable and carried from the backup.
    static let machineSpecificEnvKeys = [
        "FP_DATA_DIR", "FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR",
        "FP_GATEWAY_CONFIG", "FP_UID", "FP_GID",
    ]

    /// Reads the given keys out of the stack's current .env (KEY=VALUE lines).
    /// Comment/blank lines are skipped; keys absent from the file are omitted.
    static func readEnvValues(keys: [String]) -> [String: String] {
        let envPath = "\(homeDir)/.env"
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return [:] }
        let want = Set(keys)
        var out: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            if want.contains(key) {
                out[key] = String(trimmed[trimmed.index(after: eq)...])
            }
        }
        return out
    }

    /// Fixes up a restored .env in place:
    ///  1. rewrites any FP_AI_GATEWAY_ENABLED line to "true" (a legacy-only
    ///     key kept for older fp/tray binaries; nothing may re-persist a
    ///     disabled state);
    ///  2. re-applies the target host's machine-specific keys (`preserved`,
    ///     captured before the backup overwrote .env) over whatever the backup
    ///     carried, so a backup from another host cannot repoint this host's
    ///     data dirs / uid-gid.
    static func sanitizeRestoredEnv(preserved: [String: String] = [:]) {
        let envPath = "\(homeDir)/.env"
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }
        var mutated = false
        var lines = content.components(separatedBy: "\n")

        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("FP_AI_GATEWAY_ENABLED="), trimmed != "FP_AI_GATEWAY_ENABLED=true" {
                lines[i] = "FP_AI_GATEWAY_ENABLED=true"
                mutated = true
            }
        }

        // Re-apply preserved host-specific values: overwrite in place where
        // present, append when the backup's .env lacked the key entirely.
        for key in machineSpecificEnvKeys {
            guard let val = preserved[key] else { continue }
            let newLine = "\(key)=\(val)"
            var found = false
            for i in lines.indices {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") {
                    if lines[i] != newLine { lines[i] = newLine; mutated = true }
                    found = true
                    break
                }
            }
            if !found { lines.append(newLine); mutated = true }
        }

        if mutated {
            try? lines.joined(separator: "\n").write(toFile: envPath, atomically: true, encoding: .utf8)
        }
    }

    /// Walks the has_more / next_offset pagination envelope on a list
    /// endpoint until exhaustion and returns a single JSON document of the
    /// form `{"<sectionKey>": [...]}`. Required for /api/v1/series, which
    /// Core caps at output_max_rows (default 1000) per page regardless of
    /// the client-supplied limit.
    ///
    /// Returns nil only if the first page fails (caller writes a stub then).
    /// Mid-pagination failures stop early and return what we collected so
    /// far.
    static func harvestPaginated(path: String, sectionKey: String, token: String) -> Data? {
        let pageLimit = 1000
        let maxIterations = 10_000
        var all: [Any] = []
        var offset = 0
        let separator = path.contains("?") ? "&" : "?"

        for i in 0..<maxIterations {
            let paged = "\(path)\(separator)limit=\(pageLimit)&offset=\(offset)"
            guard let url = URL(string: "\(coreBaseURL)\(paged)") else { return nil }
            var req = URLRequest(url: url)
            req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? syncRequest(req) else {
                if i == 0 { return nil }
                break
            }

            // Pull out the array from the response. Try keyed, then aliases,
            // then "items", then bare array.
            var pageItems: [Any] = []
            var hasMore = false
            var nextOffset = offset + 1
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let arr = obj[sectionKey] as? [Any] {
                    pageItems = arr
                } else if let arr = obj[sectionKey.replacingOccurrences(of: "_", with: "-")] as? [Any] {
                    pageItems = arr
                } else if let arr = obj["items"] as? [Any] {
                    pageItems = arr
                }
                if let m = obj["has_more"] as? Bool { hasMore = m }
                if let n = obj["next_offset"] as? Int { nextOffset = n }
                else if let n = obj["next_offset"] as? Double { nextOffset = Int(n) }
            } else if let bare = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                pageItems = bare
            }

            all.append(contentsOf: pageItems)

            if !hasMore || nextOffset <= offset || pageItems.isEmpty {
                break
            }
            offset = nextOffset
        }

        let out: [String: Any] = [sectionKey: all, "count": all.count]
        return try? JSONSerialization.data(withJSONObject: out)
    }

    /// Normalise a list-endpoint JSON response into a flat array of objects.
    /// The Core API has three possible shapes:
    ///   - `[{...}, {...}]`                  ← bare array
    ///   - `{"items": [...]}`                ← generic wrapper
    ///   - `{"users": [...]}`                ← keyed by entity name
    static func extractItems(from data: Data, sectionKey: String) -> [[String: Any]] {
        // Bare array first
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr
        }
        // Object wrapper
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let arr = obj[sectionKey] as? [[String: Any]] { return arr }
        if let arr = obj["items"] as? [[String: Any]] { return arr }
        // Aliases: hyphen↔underscore, singular form
        let dashed = sectionKey.replacingOccurrences(of: "_", with: "-")
        if let arr = obj[dashed] as? [[String: Any]] { return arr }
        if sectionKey.hasSuffix("s") {
            let singular = String(sectionKey.dropLast())
            if let arr = obj[singular] as? [[String: Any]] { return arr }
        }
        return []
    }

    /// Strip server-assigned fields so POST creates a fresh record with
    /// natural-key matching instead of cloning source-instance IDs.
    static func stripServerIDs(_ item: [String: Any]) -> [String: Any] {
        let stripKeys: Set<String> = [
            "id", "created_at", "updated_at", "disk_bytes",
            "point_count", "first_timestamp", "last_timestamp",
            "last_value_ts", "last_value",
        ]
        var out: [String: Any] = [:]
        out.reserveCapacity(item.count)
        for (k, v) in item where !stripKeys.contains(k) {
            out[k] = v
        }
        return out
    }

    /// POST /api/v1/series requires an "asset" field (the asset PATH) to place
    /// the series under. GET /api/v1/series emits the full series "path"
    /// ("name@asset.path") and a numeric "asset_id", but never a bare "asset" —
    /// so derive it from the path on import. No-op when "asset" is already
    /// present or the path has no "@".
    static func ensureSeriesAsset(_ item: [String: Any]) -> [String: Any] {
        if let a = item["asset"] as? String, !a.isEmpty { return item }
        guard let path = item["path"] as? String,
              let at = path.firstIndex(of: "@") else {
            return item
        }
        var out = item
        out["asset"] = String(path[path.index(after: at)...])
        return out
    }

    /// Restores series via POST /api/v1/series/bulk — which resolves the asset
    /// by path AND applies the engineering limits + alarm thresholds carried in
    /// the export, so series arrive ready to use (definition + limits + alarm
    /// setpoints). Batched under the server's 5000-item bulk cap.
    static func importSeriesBulk(items: [[String: Any]], creds: AdminCredentials, coreBaseURL: String) {
        let batchSize = 1000
        var start = 0
        while start < items.count {
            let end = min(start + batchSize, items.count)
            let batch = items[start..<end].map { ensureSeriesAsset(stripServerIDs($0)) }
            start = end
            let payload: [String: Any] = ["series": batch]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let url = URL(string: "\(coreBaseURL)/api/v1/series/bulk")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            if Self.isImportFailure(Self.requestStatus(req)) { Self.lastImportErrorCount += 1 }
        }
    }
}

// Import CommonCrypto for PBKDF2 (bridging)
import CommonCrypto
