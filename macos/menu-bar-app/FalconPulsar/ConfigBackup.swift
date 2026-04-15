import Foundation
import AppKit
import CryptoKit

// =============================================================================
//  FalconPulsar configuration backup format (.fpconfig)
// =============================================================================
//  Outer framing (binary):
//    [0..3]   Magic = "FPCF"                 (4 bytes)
//    [4]      Format version = 1             (1 byte)
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
//    files/.env
//    files/gateway.yaml
//    api/users.json                ← GET /api/v1/users
//    api/datasources.json          ← GET /api/v1/datasources
//    api/mappings.json             ← GET /api/v1/mappings
//    api/assets.json               ← GET /api/v1/assets
//    knowledge/**                  ← optional, ai-gateway/knowledge/ if present
// =============================================================================

enum ConfigBackup {
    static let magic: [UInt8] = [0x46, 0x50, 0x43, 0x46]  // "FPCF"
    static let formatVersion: UInt8 = 1
    static let pbkdf2Iterations: UInt32 = 100_000
    static let saltLength = 16
    static let nonceLength = 12
    static let homeDir: String = "\(NSHomeDirectory())/falconpulsar"

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
            case .notAdmin:             return "Only administrator accounts can export or import configuration."
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

    /// Validates credentials against Core at http://localhost:7433 and verifies
    /// the user has the admin role. Returns an AdminCredentials with the auth
    /// token on success; throws BackupError otherwise.
    static func authenticateAsAdmin(username: String, password: String) throws -> AdminCredentials {
        let loginURL = URL(string: "http://localhost:7433/api/v1/auth/login")!
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password
        ])
        let (data, token) = try syncRequest(req)
        guard let tokenString = token ?? (try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any])?["token"] as? String,
              !tokenString.isEmpty else {
            throw BackupError.loginFailed("no token returned")
        }

        // Verify role
        let meURL = URL(string: "http://localhost:7433/api/v1/auth/me")!
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

    // MARK: - PBKDF2 + AES-GCM

    static func deriveKey(username: String, password: String, salt: Data) throws -> SymmetricKey {
        let passphrase = "\(username):\(password)"
        guard let passData = passphrase.data(using: .utf8) else {
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
        guard data[4] == formatVersion else {
            throw BackupError.invalidFile("unsupported format version \(data[4])")
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

        // API harvest
        let apiDir = "\(workDir)/api"
        try fm.createDirectory(atPath: apiDir, withIntermediateDirectories: true)
        for (name, path) in [
            ("users.json",       "/api/v1/users"),
            ("datasources.json", "/api/v1/datasources"),
            ("mappings.json",    "/api/v1/mappings"),
            ("assets.json",      "/api/v1/assets"),
            ("roles.json",       "/api/v1/roles"),
        ] {
            let url = URL(string: "http://localhost:7433\(path)")!
            var req = URLRequest(url: url)
            req.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? syncRequest(req) {
                fm.createFile(atPath: "\(apiDir)/\(name)", contents: data)
            }
        }

        // Manifest
        let hostName = Host.current().localizedName ?? "unknown"
        let df = ISO8601DateFormatter()
        let manifest: [String: Any] = [
            "format_version": 1,
            "falconpulsar_version": "0.1.0",
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
            for name in ["compose.yml", ".env", "gateway.yaml"] {
                let src = "\(filesDir)/\(name)"
                let dst = "\(homeDir)/\(name)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try fm.copyItem(atPath: src, toPath: dst)
                }
            }
        }

        // Push API data back (best-effort; resource types may not all accept
        // bulk upsert). Records that POST returns a conflict are skipped.
        let apiDir = "\(workDir)/api"
        for (name, path) in [
            ("roles.json",       "/api/v1/roles"),
            ("users.json",       "/api/v1/users"),
            ("datasources.json", "/api/v1/datasources"),
            ("assets.json",      "/api/v1/assets"),
            ("mappings.json",    "/api/v1/mappings"),
        ] {
            let file = "\(apiDir)/\(name)"
            guard fm.fileExists(atPath: file),
                  let json = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]]
            else { continue }
            for item in arr {
                let url = URL(string: "http://localhost:7433\(path)")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.addValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
                req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: item)
                _ = try? syncRequest(req)   // best-effort; ignore individual failures
            }
        }
    }
}

// Import CommonCrypto for PBKDF2 (bridging)
import CommonCrypto
