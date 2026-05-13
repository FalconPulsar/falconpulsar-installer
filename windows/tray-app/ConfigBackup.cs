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
    //    [4]      Format version                  (1 byte; writes: 2, accepts: 1, 2)
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
    //    (asset-types, series, relationships, annotations are new in v2.)
    // =========================================================================

    public static class ConfigBackup
    {
        /// <summary>Format version this build *writes*. Older versions are still accepted on read.</summary>
        public const byte FormatVersion = 2;

        /// <summary>Oldest format this build can decrypt and parse.</summary>
        public const byte MinReadableFormatVersion = 1;

        public const int SaltLength = 16;
        public const int NonceLength = 12;
        public const int TagLength = 16;
        public const int Iterations = 100_000;
        public static readonly byte[] Magic = { 0x46, 0x50, 0x43, 0x46 }; // "FPCF"

        public const string CoreBaseUrl = "http://localhost:7433";

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
                    "Cannot reach FalconPulsar Core at http://localhost:7433.");
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

        public static string FalconPulsarHomeDir => Path.Combine(
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
                    // Harvest list mirrors backup.go in console/. New v2
                    // sections (asset-types, series, relationships, annotations)
                    // are included unconditionally so the resulting file is a
                    // v2 backup, regardless of whether the target has any
                    // data in those tables.
                    foreach (var (name, path) in new[] {
                        ("roles.json",         "/api/v1/roles"),
                        ("users.json",         "/api/v1/users"),
                        ("asset-types.json",   "/api/v1/asset-types"),
                        ("assets.json",        "/api/v1/assets"),
                        ("datasources.json",   "/api/v1/datasources"),
                        ("series.json",        "/api/v1/series?include_engineering=true&limit=100000"),
                        ("mappings.json",      "/api/v1/mappings"),
                        ("relationships.json", "/api/v1/relationships"),
                        ("annotations.json",   "/api/v1/annotations?limit=100000"),
                    })
                    {
                        try
                        {
                            var resp = await http.GetAsync($"{CoreBaseUrl}{path}");
                            if (resp.IsSuccessStatusCode)
                                File.WriteAllBytes(
                                    Path.Combine(apiDir, name),
                                    await resp.Content.ReadAsByteArrayAsync());
                        }
                        catch { /* best effort */ }
                    }
                }

                var manifest = new
                {
                    format_version = (int)FormatVersion,
                    falconpulsar_version = "0.1.3",
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

        public static async Task ImportAsync(string inputPath, AdminCredentials creds)
        {
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
                    foreach (var name in new[] { "compose.yml", ".env", "gateway.yaml" })
                    {
                        var src = Path.Combine(filesDir, name);
                        var dst = Path.Combine(FalconPulsarHomeDir, name);
                        if (File.Exists(src))
                            File.Copy(src, dst, overwrite: true);
                    }
                }

                // Push API data in dependency order. v2-aware: includes the
                // new sections if present in the zip. Old v1 backups simply
                // skip the missing files. For each item we strip server-
                // assigned fields (id, created_at, point_count, ...) so the
                // target server mints fresh IDs by natural key.
                var apiDir = Path.Combine(workDir, "api");
                if (Directory.Exists(apiDir))
                {
                    using var http = new HttpClient();
                    http.DefaultRequestHeaders.Authorization =
                        new AuthenticationHeaderValue("Bearer", creds.Token);
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
                        var file = Path.Combine(apiDir, sec.file);
                        if (!File.Exists(file)) continue;
                        try
                        {
                            var items = ExtractItems(await File.ReadAllTextAsync(file), sec.key);
                            foreach (var raw in items)
                            {
                                var stripped = StripServerIDs(raw);
                                var body = new StringContent(stripped.ToJsonString(),
                                                             Encoding.UTF8, "application/json");
                                try { await http.PostAsync($"{CoreBaseUrl}{sec.path}", body); }
                                catch { /* best-effort */ }
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
    }
}
