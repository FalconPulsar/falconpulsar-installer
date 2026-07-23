using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace FalconPulsar.Tray
{
    // =========================================================================
    //  FalconPulsar configuration backup format (.fpconfig)
    //  ---- THIS MUST STAY IN SYNC WITH macOS ConfigBackup.swift and
    //  ---- console/internal/configbackup/backup.go (Linux fp CLI).
    //  ---- The authoritative spec lives in the Go file.
    //
    //  Outer framing (binary):
    //    [0..3]   Magic = "FPCF"                 (4 bytes)
    //    [4]      Format version                  (1 byte; writes: 3, accepts: 1, 2, 3)
    //    [5..20]  PBKDF2 salt                    (16 bytes)
    //    [21..32] AES-GCM nonce/IV               (12 bytes)
    //    [33..]   AES-256-GCM ciphertext of the zip payload
    //    [last 16 bytes]   GCM auth tag
    //
    //  Key:
    //    PBKDF2-HMAC-SHA256(password="<user>:<pass>", salt=<salt>,
    //                       iter=100_000, keyLen=32)
    //
    //  Payload (zip):
    //    manifest.json, files/{compose.yml,.env,gateway.yaml},
    //    api/{roles,users,asset-types,assets,datasources,series,mappings,
    //         relationships,annotations}.json
    //    api/config-bundle.json  ← GET /api/v1/admin/config-bundle (new in v3):
    //         the complete-server secrets — user password hashes+salts, MFA
    //         secrets, API-token records, roles, and layout/favorite/label/
    //         preference KV. Treated as an OPAQUE blob (bytes GET → zip → POST),
    //         never parsed. Applied first on import.
    //    (asset-types, series, relationships, annotations are new in v2.)
    //
    //  Format version compatibility:
    //    v1: 5 sections (users, roles, datasources, mappings, assets).
    //    v2: adds asset-types, series, relationships, annotations. v1 files
    //        still import (missing sections skipped silently).
    //    v3: adds config-bundle.json. On import it is applied FIRST (restoring
    //        users/roles/tokens/layouts verbatim, with secrets); the users+roles
    //        REST sections are then skipped. A v3 file is rejected at the
    //        version-byte check by a v1/v2-only client.
    // =========================================================================

    public static class ConfigBackup
    {
        /// <summary>
        /// Format version this build *writes*. Older versions are still
        /// accepted on read (see Decrypt validation).
        ///
        /// v3 adds api/config-bundle.json — the admin-only "complete server"
        /// bundle from GET /api/v1/admin/config-bundle: user password hashes +
        /// salts, MFA secrets, API-token records, roles, and the canvas
        /// layout/favorite/label/preference KV. It is the ONE class of data
        /// normal REST never returns, so a v3 restore rebuilds a server with the
        /// SAME passwords, tokens, MFA, and dashboards. The bundle is applied
        /// first on import; when present, the users+roles REST sections are
        /// skipped (the bundle already restored them verbatim, with secrets).
        /// </summary>
        public const byte FormatVersion = 3;

        /// <summary>Oldest format this build can decrypt and parse.</summary>
        public const byte MinReadableFormatVersion = 1;

        public const int SaltLength = 16;
        public const int NonceLength = 12;
        public const int TagLength = 16;
        public const int Iterations = 100_000;
        public static readonly byte[] Magic = { 0x46, 0x50, 0x43, 0x46 }; // "FPCF"

        /// <summary>
        /// Core's base URL. The REST port comes from the stack's .env
        /// (FP_REST_PORT) so port-remapped installs still reach Core; 7433
        /// is only the installer default, used when .env is missing or
        /// doesn't set the key. FalconPulsarHomeDir is pointed at the
        /// resolved WSL UNC stack dir by TrayApp at startup, so this reads
        /// the same .env the stack itself runs with.
        /// </summary>
        public static string CoreBaseUrl => $"http://localhost:{RestPort()}";

        // Last occurrence wins, matching docker compose's env-file
        // semantics (mirrors TrayApp.EnvValue / macOS AppDelegate.envValue).
        private static string RestPort()
        {
            try
            {
                var envPath = Path.Combine(FalconPulsarHomeDir, ".env");
                if (!File.Exists(envPath)) return "7433";
                string port = null;
                foreach (var line in File.ReadAllLines(envPath))
                {
                    var trimmed = line.Trim();
                    if (!trimmed.StartsWith("FP_REST_PORT=")) continue;
                    var v = trimmed.Substring("FP_REST_PORT=".Length).Trim();
                    if (v.Length > 0) port = v;
                }
                return string.IsNullOrEmpty(port) ? "7433" : port;
            }
            catch
            {
                // UNC reads can fail while WSL is starting/stopping —
                // fall back to the installer default.
                return "7433";
            }
        }

        public class AdminCredentials
        {
            public string Username { get; set; } = "";
            public string Password { get; set; } = "";
            public string Token { get; set; } = "";
        }

        public class BackupException : Exception
        {
            public BackupException(string message) : base(message) { }
        }

        // ---- Auth + admin check ----

        public static async Task<AdminCredentials> AuthenticateAsAdminAsync(string user, string pass)
        {
            using var http = new HttpClient();
            var loginBody = JsonSerializer.Serialize(new { username = user, password = pass });
            HttpResponseMessage loginResp;
            try
            {
                loginResp = await http.PostAsync(
                    $"{CoreBaseUrl}/api/v1/auth/login",
                    new StringContent(loginBody, Encoding.UTF8, "application/json"));
            }
            catch (HttpRequestException)
            {
                throw new BackupException(
                    $"Cannot reach FalconPulsar Core at {CoreBaseUrl}.");
            }

            if (!loginResp.IsSuccessStatusCode)
            {
                var status = (int)loginResp.StatusCode;
                if (status == 401)
                    throw new BackupException("Incorrect username or password.");
                if (status == 403)
                    throw new BackupException("Access denied.");
                throw new BackupException(
                    $"Cannot reach FalconPulsar Core (HTTP {status}). Check that the stack is running.");
            }

            var loginJson = JsonNode.Parse(await loginResp.Content.ReadAsStringAsync());
            var token = loginJson?["token"]?.GetValue<string>();
            if (string.IsNullOrEmpty(token))
                throw new BackupException("No token returned by server.");

            using var meReq = new HttpRequestMessage(HttpMethod.Get, $"{CoreBaseUrl}/api/v1/auth/me");
            meReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            var meResp = await http.SendAsync(meReq);
            if (!meResp.IsSuccessStatusCode)
                throw new BackupException("Could not read user role.");

            var meJson = JsonNode.Parse(await meResp.Content.ReadAsStringAsync());
            var role = meJson?["role"]?.GetValue<string>();
            if (role == null && meJson?["roles"] is JsonArray arr && arr.Count > 0)
                role = arr[0]?.GetValue<string>();
            if (!string.Equals(role, "admin", StringComparison.OrdinalIgnoreCase))
                throw new BackupException(
                    "This account is not an administrator. Ask your administrator for help.");

            return new AdminCredentials { Username = user, Password = pass, Token = token };
        }

        // ---- Crypto ----

        private static byte[] DeriveKey(string user, string pass, byte[] salt)
        {
            // The passphrase buffer holds cleartext "user:pass" during PBKDF2.
            // Zero it immediately after use so it doesn't linger on the heap.
            var passphrase = Encoding.UTF8.GetBytes($"{user}:{pass}");
            try
            {
                using var kdf = new Rfc2898DeriveBytes(passphrase, salt, Iterations, HashAlgorithmName.SHA256);
                return kdf.GetBytes(32);
            }
            finally
            {
                Array.Clear(passphrase, 0, passphrase.Length);
            }
        }

        public static byte[] Encrypt(byte[] plaintext, string user, string pass)
        {
            var salt  = RandomNumberGenerator.GetBytes(SaltLength);
            var nonce = RandomNumberGenerator.GetBytes(NonceLength);
            var key   = DeriveKey(user, pass, salt);
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[TagLength];
            try
            {
                using (var gcm = new AesGcm(key, TagLength))
                {
                    gcm.Encrypt(nonce, plaintext, ciphertext, tag);
                }
                using var ms = new MemoryStream();
                ms.Write(Magic, 0, Magic.Length);
                ms.WriteByte(FormatVersion);
                ms.Write(salt, 0, salt.Length);
                ms.Write(nonce, 0, nonce.Length);
                ms.Write(ciphertext, 0, ciphertext.Length);
                ms.Write(tag, 0, tag.Length);
                return ms.ToArray();
            }
            finally
            {
                // Zero the derived key and the plaintext buffer — both
                // contain sensitive material from the backup.
                Array.Clear(key, 0, key.Length);
                Array.Clear(plaintext, 0, plaintext.Length);
            }
        }

        public static byte[] Decrypt(byte[] data, string user, string pass)
        {
            var headerLen = Magic.Length + 1 + SaltLength + NonceLength;
            if (data.Length < headerLen + TagLength)
                throw new BackupException("Not a FalconPulsar backup file: too short.");
            for (int i = 0; i < Magic.Length; i++)
                if (data[i] != Magic[i])
                    throw new BackupException("Not a FalconPulsar backup file: magic mismatch.");
            // Accept any version we know how to read. The version byte is
            // authenticated by the GCM tag, so a tampered value would fail
            // decryption later.
            var v = data[Magic.Length];
            if (v < MinReadableFormatVersion || v > FormatVersion)
                throw new BackupException(
                    $"Unsupported backup format version {v} (this client supports v{MinReadableFormatVersion}–v{FormatVersion}).");

            var salt  = new byte[SaltLength];  Array.Copy(data, 5, salt, 0, SaltLength);
            var nonce = new byte[NonceLength]; Array.Copy(data, 5 + SaltLength, nonce, 0, NonceLength);
            var bodyLen = data.Length - headerLen - TagLength;
            var ciphertext = new byte[bodyLen];
            Array.Copy(data, headerLen, ciphertext, 0, bodyLen);
            var tag = new byte[TagLength];
            Array.Copy(data, headerLen + bodyLen, tag, 0, TagLength);

            var key = DeriveKey(user, pass, salt);
            var plaintext = new byte[bodyLen];
            try
            {
                using var gcm = new AesGcm(key, TagLength);
                gcm.Decrypt(nonce, ciphertext, tag, plaintext);
                return plaintext;
            }
            catch (CryptographicException)
            {
                Array.Clear(plaintext, 0, plaintext.Length);
                throw new BackupException("Decryption failed — wrong admin credentials or corrupted file.");
            }
            finally
            {
                // The caller owns the returned plaintext from here; we only
                // need to wipe the derived key in this scope.
                Array.Clear(key, 0, key.Length);
            }
        }

        // ---- Export / Import ----

        // Stack directory holding compose.yml/.env/gateway.yaml. The real
        // files live inside WSL; TrayApp points this at the resolved
        // \\wsl.localhost\<distro>\<home>\falconpulsar UNC path at startup.
        // The default below is the legacy Windows-side mirror, kept only as
        // a fallback for callers that never set it.
        public static string FalconPulsarHomeDir { get; set; } = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "falconpulsar");

        public static async Task ExportAsync(string outputPath, AdminCredentials creds)
        {
            var workDir = Path.Combine(Path.GetTempPath(), "fpconfig-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDir);
            try
            {
                var filesDir = Path.Combine(workDir, "files");
                Directory.CreateDirectory(filesDir);
                foreach (var name in new[] { "compose.yml", ".env", "gateway.yaml" })
                {
                    var src = Path.Combine(FalconPulsarHomeDir, name);
                    if (File.Exists(src))
                        File.Copy(src, Path.Combine(filesDir, name), overwrite: true);
                }

                var apiDir = Path.Combine(workDir, "api");
                Directory.CreateDirectory(apiDir);
                using (var http = new HttpClient())
                {
                    http.DefaultRequestHeaders.Authorization =
                        new AuthenticationHeaderValue("Bearer", creds.Token);
                    // Harvest list mirrors backup.go in console/. Each section
                    // is fetched via HarvestPaginatedAsync which walks
                    // has_more/next_offset until exhaustion — required for
                    // /api/v1/series, which Core caps at output_max_rows
                    // (default 1000) per page regardless of any ?limit= the
                    // client supplies.
                    var sections = new (string file, string path, string key)[] {
                        ("roles.json",         "/api/v1/roles",                                "roles"),
                        ("users.json",         "/api/v1/users",                                "users"),
                        ("asset-types.json",   "/api/v1/asset-types",                          "asset_types"),
                        ("assets.json",        "/api/v1/assets",                               "assets"),
                        ("datasources.json",   "/api/v1/datasources",                          "datasources"),
                        ("series.json",        "/api/v1/series?include_engineering=true",      "series"),
                        ("mappings.json",      "/api/v1/mappings",                             "mappings"),
                        ("relationships.json", "/api/v1/relationships",                        "relationships"),
                        ("annotations.json",   "/api/v1/annotations",                          "annotations"),
                    };
                    foreach (var sec in sections)
                    {
                        try
                        {
                            var bytes = await HarvestPaginatedAsync(http, sec.path, sec.key);
                            File.WriteAllBytes(Path.Combine(apiDir, sec.file), bytes);
                        }
                        catch
                        {
                            // Empty stub so import can run with what we got.
                            File.WriteAllText(Path.Combine(apiDir, sec.file),
                                              $"{{\"{sec.key}\":[]}}");
                        }
                    }

                    // v3: the complete server bundle — password hashes, MFA
                    // secrets, API tokens, roles, layouts, favorites, labels,
                    // preferences. This is the ONLY source of the secrets a real
                    // "restore a server" needs; the whole backup is AES-encrypted
                    // so these never touch disk in the clear. Treated as an
                    // OPAQUE blob: GET body → zip entry → POST body on import,
                    // never parsed. A server too old to expose the endpoint (404)
                    // simply yields no bundle and the backup degrades to v2
                    // behaviour on import. This is the LAST api/* entry added
                    // before the zip is created.
                    try
                    {
                        using var bundleResp = await http.GetAsync(
                            $"{CoreBaseUrl}/api/v1/admin/config-bundle");
                        if (bundleResp.IsSuccessStatusCode)
                        {
                            var bundle = await bundleResp.Content.ReadAsByteArrayAsync();
                            if (bundle.Length > 0)
                                File.WriteAllBytes(
                                    Path.Combine(apiDir, "config-bundle.json"), bundle);
                        }
                    }
                    catch
                    {
                        // Older Core without the endpoint, or a transient
                        // failure — skip silently; backup degrades to v2.
                    }
                }

                // falconpulsar_version mirrors the assembly version (set at
                // build time via <Version> in FalconPulsarTray.csproj,
                // overridden by CI with -p:Version=...), same as the About
                // panel.
                var asmVersion = System.Reflection.Assembly
                    .GetExecutingAssembly()
                    .GetName()
                    .Version?.ToString(3) ?? "dev";
                var manifest = new
                {
                    format_version = (int)FormatVersion,
                    falconpulsar_version = asmVersion,
                    exported_at = DateTime.UtcNow.ToString("o"),
                    source_host = Environment.MachineName,
                    source_platform = "Windows"
                };
                File.WriteAllText(
                    Path.Combine(workDir, "manifest.json"),
                    JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));

                var zipPath = Path.Combine(Path.GetTempPath(), "fpconfig-" + Guid.NewGuid().ToString("N") + ".zip");
                try
                {
                    ZipFile.CreateFromDirectory(workDir, zipPath, CompressionLevel.Optimal, false);
                    var plain = File.ReadAllBytes(zipPath);
                    var encrypted = Encrypt(plain, creds.Username, creds.Password);
                    File.WriteAllBytes(outputPath, encrypted);
                }
                finally { try { File.Delete(zipPath); } catch { } }
            }
            finally
            {
                try { Directory.Delete(workDir, recursive: true); } catch { }
            }
        }

        // .env keys tied to the HOST the stack runs on — absolute host paths
        // and the host uid/gid — rather than the logical configuration. On
        // restore they must keep the TARGET host's values, never the backup's,
        // or a cross-host restore repoints core's bind mount at a non-existent
        // path and the container crash-loops. Everything else in .env (secrets,
        // ports, flags, admin user) is portable and carried from the backup.
        private static readonly string[] MachineSpecificEnvKeys =
        {
            "FP_DATA_DIR", "FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR",
            "FP_GATEWAY_CONFIG", "FP_UID", "FP_GID",
        };

        // Reads the given keys out of a KEY=VALUE .env file. Comment/blank
        // lines are skipped; keys absent from the file are omitted. Never
        // throws (missing file -> empty map).
        private static Dictionary<string, string> ReadEnvValues(string path, string[] keys)
        {
            var result = new Dictionary<string, string>();
            if (!File.Exists(path)) return result;
            var want = new HashSet<string>(keys);
            foreach (var raw in File.ReadAllLines(path))
            {
                var trimmed = raw.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith("#")) continue;
                int eq = trimmed.IndexOf('=');
                if (eq <= 0) continue;
                var key = trimmed.Substring(0, eq);
                if (want.Contains(key))
                    result[key] = trimmed.Substring(eq + 1);
            }
            return result;
        }

        /// <summary>Number of model items the last ImportAsync could not restore
        /// (a datasource/mapping/etc. the server rejected). Reset at the start of
        /// each import; read by the tray to warn instead of a silent "success".</summary>
        public static int LastImportErrorCount;

        public static async Task ImportAsync(string inputPath, AdminCredentials creds)
        {
            LastImportErrorCount = 0;
            var encrypted = File.ReadAllBytes(inputPath);
            var plain = Decrypt(encrypted, creds.Username, creds.Password);

            var workDir = Path.Combine(Path.GetTempPath(), "fpconfig-in-" + Guid.NewGuid().ToString("N"));
            var zipPath = Path.Combine(Path.GetTempPath(), "fpconfig-in-" + Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                File.WriteAllBytes(zipPath, plain);
                Directory.CreateDirectory(workDir);
                ZipFile.ExtractToDirectory(zipPath, workDir);

                // Restore config files
                var filesDir = Path.Combine(workDir, "files");
                if (Directory.Exists(filesDir))
                {
                    Directory.CreateDirectory(FalconPulsarHomeDir);

                    // Preserve the target host's machine-specific .env values
                    // (absolute paths + uid/gid). A backup taken on another
                    // host carries ITS FP_DATA_DIR etc.; restoring those
                    // verbatim repoints core's bind mount at a path that does
                    // not exist on this host -> Docker mounts an empty dir ->
                    // core sees no database and crash-loops on first-run init.
                    // Capture the current values BEFORE the backup's .env
                    // overwrites them, then re-apply them below.
                    var envPath = Path.Combine(FalconPulsarHomeDir, ".env");
                    var preservedEnv = ReadEnvValues(envPath, MachineSpecificEnvKeys);

                    foreach (var name in new[] { "compose.yml", ".env", "gateway.yaml" })
                    {
                        var src = Path.Combine(filesDir, name);
                        var dst = Path.Combine(FalconPulsarHomeDir, name);
                        if (File.Exists(src))
                            File.Copy(src, dst, overwrite: true);
                    }

                    // Fix up the restored .env: force FP_AI_GATEWAY_ENABLED to
                    // true (legacy-only key, mandatory component), and re-apply
                    // the preserved machine-specific keys over whatever the
                    // backup carried.
                    if (File.Exists(envPath))
                    {
                        var lines = new List<string>(File.ReadAllLines(envPath));
                        bool changed = false;
                        for (int i = 0; i < lines.Count; i++)
                        {
                            var trimmed = lines[i].TrimStart();
                            if (trimmed.StartsWith("FP_AI_GATEWAY_ENABLED=") &&
                                trimmed != "FP_AI_GATEWAY_ENABLED=true")
                            {
                                lines[i] = "FP_AI_GATEWAY_ENABLED=true";
                                changed = true;
                            }
                        }
                        // Re-apply preserved host-specific values: overwrite in
                        // place where present, append when the backup lacked it.
                        foreach (var key in MachineSpecificEnvKeys)
                        {
                            if (!preservedEnv.TryGetValue(key, out var val)) continue;
                            var newLine = key + "=" + val;
                            bool found = false;
                            for (int i = 0; i < lines.Count; i++)
                            {
                                if (lines[i].TrimStart().StartsWith(key + "="))
                                {
                                    if (lines[i] != newLine) { lines[i] = newLine; changed = true; }
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) { lines.Add(newLine); changed = true; }
                        }
                        // Write with LF line endings: this .env lives inside
                        // WSL and is sourced by bash, which would treat the
                        // CR from WriteAllLines' CRLF as part of every value.
                        if (changed)
                            File.WriteAllText(envPath, string.Join("\n", lines) + "\n");
                    }
                }

                // Push API data in dependency order. v3-aware: includes the
                // v2 sections if present in the zip, and applies the v3
                // config-bundle first (below). Old v1 backups simply skip the
                // missing files. For each item we strip server-assigned fields
                // (id, created_at, point_count, ...) so the target server mints
                // fresh IDs by natural key.
                var apiDir = Path.Combine(workDir, "api");
                if (Directory.Exists(apiDir))
                {
                    using var http = new HttpClient();
                    http.DefaultRequestHeaders.Authorization =
                        new AuthenticationHeaderValue("Bearer", creds.Token);

                    // v3: apply the complete server bundle FIRST — it restores
                    // users (with their password hashes + MFA), roles, API
                    // tokens, and the canvas layout/favorite/label/preference KV
                    // verbatim via the admin endpoint. When it applies, the
                    // users+roles REST sections below are skipped so a verbatim,
                    // password-preserving restore isn't overwritten by the
                    // password-less REST create path. The bundle is an OPAQUE
                    // blob: its bytes are POSTed verbatim, never parsed.
                    bool bundleApplied = false;
                    var bundleFile = Path.Combine(apiDir, "config-bundle.json");
                    if (File.Exists(bundleFile))
                    {
                        try
                        {
                            var bundleBytes = await File.ReadAllBytesAsync(bundleFile);
                            var bundleBody = new ByteArrayContent(bundleBytes);
                            bundleBody.Headers.ContentType =
                                new MediaTypeHeaderValue("application/json");
                            var bundleResp = await http.PostAsync(
                                $"{CoreBaseUrl}/api/v1/admin/config-bundle", bundleBody);
                            if (bundleResp.IsSuccessStatusCode)
                                bundleApplied = true;
                        }
                        catch { /* best-effort; fall through to the REST sections */ }
                    }

                    var sections = new (string file, string path, string key)[] {
                        ("roles.json",         "/api/v1/roles",         "roles"),
                        ("asset-types.json",   "/api/v1/asset-types",   "asset_types"),
                        ("users.json",         "/api/v1/users",         "users"),
                        ("datasources.json",   "/api/v1/datasources",   "datasources"),
                        ("assets.json",        "/api/v1/assets",        "assets"),
                        ("series.json",        "/api/v1/series",        "series"),
                        ("mappings.json",      "/api/v1/mappings",      "mappings"),
                        ("relationships.json", "/api/v1/relationships", "relationships"),
                        ("annotations.json",   "/api/v1/annotations",   "annotations"),
                    };
                    foreach (var sec in sections)
                    {
                        // When the v3 bundle applied, users + roles were restored
                        // verbatim (with password hashes + secrets). Re-running the
                        // REST create path for them would only add password-less
                        // duplicates / 409s.
                        if (bundleApplied && (sec.key == "users" || sec.key == "roles"))
                            continue;
                        var file = Path.Combine(apiDir, sec.file);
                        if (!File.Exists(file)) continue;
                        try
                        {
                            var items = ExtractItems(await File.ReadAllTextAsync(file), sec.key);
                            // Series restore their FULL config in one bulk call:
                            // POST /api/v1/series/bulk resolves the asset by path AND
                            // applies the engineering limits + alarm thresholds,
                            // unlike the per-item POST /api/v1/series (which needs an
                            // "asset" field the export never emits and drops the
                            // limits/thresholds entirely).
                            if (sec.key == "series")
                            {
                                await ImportSeriesBulkAsync(http, items);
                                continue;
                            }
                            foreach (var raw in items)
                            {
                                var stripped = StripServerIDs(raw);
                                var body = new StringContent(stripped.ToJsonString(),
                                                             Encoding.UTF8, "application/json");
                                // Count (don't swallow) a server rejection so the tray
                                // can warn — a rejected datasource/mapping leaves dead
                                // series. PostAsync does NOT throw on 4xx/5xx, so the
                                // status check is what actually catches it.
                                try
                                {
                                    var resp = await http.PostAsync($"{CoreBaseUrl}{sec.path}", body);
                                    if (!resp.IsSuccessStatusCode && (int)resp.StatusCode != 409)
                                        LastImportErrorCount++;
                                }
                                catch { LastImportErrorCount++; }
                            }
                        }
                        catch { /* skip malformed */ }
                    }
                }
            }
            finally
            {
                try { File.Delete(zipPath); } catch { }
                try { Directory.Delete(workDir, recursive: true); } catch { }
            }
        }

        /// <summary>
        /// Walks the has_more / next_offset pagination envelope on a list
        /// endpoint until exhaustion and returns a single JSON document of
        /// the form {"&lt;sectionKey&gt;": [...]}. Required for /api/v1/series,
        /// which Core caps at output_max_rows (default 1000) per page
        /// regardless of any client-supplied ?limit=.
        ///
        /// On error returns an empty {"&lt;sectionKey&gt;":[]} stub so the
        /// import side can still run with the rest of the backup.
        /// </summary>
        private static async Task<byte[]> HarvestPaginatedAsync(
            HttpClient http, string basePath, string sectionKey)
        {
            const int pageLimit = 1000;
            const int maxIterations = 10_000;
            var all = new JsonArray();
            int offset = 0;
            string separator = basePath.Contains('?') ? "&" : "?";

            for (int i = 0; i < maxIterations; i++)
            {
                var paged = $"{basePath}{separator}limit={pageLimit}&offset={offset}";
                HttpResponseMessage resp;
                try { resp = await http.GetAsync($"{CoreBaseUrl}{paged}"); }
                catch
                {
                    if (i == 0) throw;  // propagate first-page failure
                    break;
                }
                if (!resp.IsSuccessStatusCode)
                {
                    if (i == 0)
                        throw new BackupException(
                            $"GET {paged}: HTTP {(int)resp.StatusCode}");
                    break;
                }

                var raw = await resp.Content.ReadAsStringAsync();
                JsonNode parsed;
                try { parsed = JsonNode.Parse(raw); }
                catch { break; }

                JsonArray pageItems = null;
                bool hasMore = false;
                int nextOffset = offset + 1;

                if (parsed is JsonObject obj)
                {
                    foreach (var k in new[] {
                        sectionKey,
                        sectionKey.Replace("_", "-"),
                        "items",
                    })
                    {
                        if (obj[k] is JsonArray arr)
                        {
                            pageItems = arr;
                            break;
                        }
                    }
                    if (obj["has_more"]?.GetValue<bool>() is bool m) hasMore = m;
                    if (obj["next_offset"]?.GetValue<int>() is int n) nextOffset = n;
                }
                else if (parsed is JsonArray bare)
                {
                    pageItems = bare;
                }

                if (pageItems != null)
                {
                    foreach (var item in pageItems)
                        all.Add(item?.DeepClone());
                }

                if (!hasMore || nextOffset <= offset || (pageItems?.Count ?? 0) == 0)
                    break;
                offset = nextOffset;
            }

            var outObj = new JsonObject {
                [sectionKey] = all,
                ["count"]    = all.Count,
            };
            return Encoding.UTF8.GetBytes(outObj.ToJsonString());
        }

        /// <summary>
        /// Normalises a list-endpoint JSON response into a flat array of objects.
        /// Tries bare array, then {"section":[...]} keyed, then {"items":[...]},
        /// then alias forms (hyphen↔underscore, singular).
        /// </summary>
        private static IEnumerable<JsonObject> ExtractItems(string raw, string sectionKey)
        {
            JsonNode root;
            try { root = JsonNode.Parse(raw); }
            catch { yield break; }

            if (root is JsonArray bareArr)
            {
                foreach (var n in bareArr)
                    if (n is JsonObject o) yield return o;
                yield break;
            }
            if (root is not JsonObject obj) yield break;

            JsonNode TryKey(string k) =>
                obj.ContainsKey(k) ? obj[k] : null;

            foreach (var k in new[] {
                sectionKey,
                "items",
                sectionKey.Replace("_", "-"),
                sectionKey.EndsWith("s") ? sectionKey.Substring(0, sectionKey.Length - 1) : null,
            })
            {
                if (k == null) continue;
                if (TryKey(k) is JsonArray arr)
                {
                    foreach (var n in arr)
                        if (n is JsonObject o) yield return o;
                    yield break;
                }
            }
        }

        /// <summary>
        /// Strips server-assigned fields so POST creates a fresh record on the
        /// target instead of trying to clone source-instance IDs (which would
        /// either collide or fail FK lookups).
        /// </summary>
        private static JsonObject StripServerIDs(JsonObject item)
        {
            var stripKeys = new HashSet<string> {
                "id", "created_at", "updated_at", "disk_bytes",
                "point_count", "first_timestamp", "last_timestamp",
                "last_value_ts", "last_value",
            };
            var clone = new JsonObject();
            foreach (var kv in item)
            {
                if (stripKeys.Contains(kv.Key)) continue;
                clone[kv.Key] = kv.Value?.DeepClone();
            }
            return clone;
        }

        /// <summary>
        /// POST /api/v1/series requires an "asset" field (the asset PATH) to
        /// place the series under. GET /api/v1/series emits the full series
        /// "path" ("name@asset.path") and a numeric "asset_id", but never a bare
        /// "asset" — so derive it from the path on import. No-op when "asset" is
        /// already present or the path has no "@".
        /// </summary>
        private static void EnsureSeriesAsset(JsonObject item)
        {
            if (item["asset"] is JsonValue av && av.TryGetValue<string>(out var a)
                && !string.IsNullOrEmpty(a)) return;
            if (item["path"] is JsonValue pv && pv.TryGetValue<string>(out var path)
                && !string.IsNullOrEmpty(path))
            {
                int at = path.IndexOf('@');
                if (at >= 0 && at + 1 < path.Length)
                    item["asset"] = path.Substring(at + 1);
            }
        }

        /// <summary>
        /// Restores series via POST /api/v1/series/bulk — which resolves the
        /// asset by path AND applies the engineering limits + alarm thresholds
        /// carried in the export, so series arrive ready to use (definition +
        /// limits + alarm setpoints). Batched under the 5000-item bulk cap.
        /// </summary>
        private static async Task ImportSeriesBulkAsync(HttpClient http, IEnumerable<JsonObject> items)
        {
            const int batchSize = 1000;
            var batch = new JsonArray();
            foreach (var raw in items)
            {
                var stripped = StripServerIDs(raw);
                EnsureSeriesAsset(stripped);
                batch.Add(stripped);
                if (batch.Count >= batchSize)
                {
                    await PostSeriesBatchAsync(http, batch);
                    batch = new JsonArray();
                }
            }
            if (batch.Count > 0) await PostSeriesBatchAsync(http, batch);
        }

        private static async Task PostSeriesBatchAsync(HttpClient http, JsonArray batch)
        {
            var payload = new JsonObject { ["series"] = batch };
            var body = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
            try
            {
                var resp = await http.PostAsync($"{CoreBaseUrl}/api/v1/series/bulk", body);
                if (!resp.IsSuccessStatusCode && (int)resp.StatusCode != 409)
                    LastImportErrorCount++;
            }
            catch { LastImportErrorCount++; }
        }
    }
}
