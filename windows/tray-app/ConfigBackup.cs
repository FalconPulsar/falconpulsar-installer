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
    //  ---- THIS MUST STAY IN SYNC WITH macOS ConfigBackup.swift ----
    //
    //  Outer framing (binary):
    //    [0..3]   Magic = "FPCF"                 (4 bytes)
    //    [4]      Format version = 1             (1 byte)
    //    [5..20]  PBKDF2 salt                    (16 bytes)
    //    [21..32] AES-GCM nonce/IV               (12 bytes)
    //    [33..]   AES-256-GCM ciphertext of the zip payload
    //    [last 16 bytes]   GCM auth tag
    //
    //  Key:
    //    PBKDF2-HMAC-SHA256(password="<user>:<pass>", salt=<salt>,
    //                       iter=100_000, keyLen=32)
    //
    //  Payload: zip archive
    //    manifest.json, files/compose.yml, files/.env, files/gateway.yaml,
    //    api/users.json, api/datasources.json, api/mappings.json, api/assets.json
    // =========================================================================

    public static class ConfigBackup
    {
        public const byte FormatVersion = 1;
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
            var loginResp = await http.PostAsync(
                $"{CoreBaseUrl}/api/v1/auth/login",
                new StringContent(loginBody, Encoding.UTF8, "application/json"));
            if (!loginResp.IsSuccessStatusCode)
                throw new BackupException($"Login failed: HTTP {(int)loginResp.StatusCode}");

            var loginJson = JsonNode.Parse(await loginResp.Content.ReadAsStringAsync());
            var token = loginJson?["token"]?.GetValue<string>();
            if (string.IsNullOrEmpty(token))
                throw new BackupException("Login failed: no token returned");

            using var meReq = new HttpRequestMessage(HttpMethod.Get, $"{CoreBaseUrl}/api/v1/auth/me");
            meReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            var meResp = await http.SendAsync(meReq);
            if (!meResp.IsSuccessStatusCode)
                throw new BackupException("Could not read user role");

            var meJson = JsonNode.Parse(await meResp.Content.ReadAsStringAsync());
            var role = meJson?["role"]?.GetValue<string>();
            if (role == null && meJson?["roles"] is JsonArray arr && arr.Count > 0)
                role = arr[0]?.GetValue<string>();
            if (!string.Equals(role, "admin", StringComparison.OrdinalIgnoreCase))
                throw new BackupException("Only administrator accounts can export or import configuration.");

            return new AdminCredentials { Username = user, Password = pass, Token = token };
        }

        // ---- Crypto ----

        private static byte[] DeriveKey(string user, string pass, byte[] salt)
        {
            var passphrase = Encoding.UTF8.GetBytes($"{user}:{pass}");
            using var kdf = new Rfc2898DeriveBytes(passphrase, salt, Iterations, HashAlgorithmName.SHA256);
            return kdf.GetBytes(32);
        }

        public static byte[] Encrypt(byte[] plaintext, string user, string pass)
        {
            var salt  = RandomNumberGenerator.GetBytes(SaltLength);
            var nonce = RandomNumberGenerator.GetBytes(NonceLength);
            var key   = DeriveKey(user, pass, salt);
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[TagLength];
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

        public static byte[] Decrypt(byte[] data, string user, string pass)
        {
            var headerLen = Magic.Length + 1 + SaltLength + NonceLength;
            if (data.Length < headerLen + TagLength)
                throw new BackupException("Not a FalconPulsar backup file: too short.");
            for (int i = 0; i < Magic.Length; i++)
                if (data[i] != Magic[i])
                    throw new BackupException("Not a FalconPulsar backup file: magic mismatch.");
            if (data[Magic.Length] != FormatVersion)
                throw new BackupException($"Unsupported backup format version: {data[Magic.Length]}");

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
            }
            catch (CryptographicException)
            {
                throw new BackupException("Decryption failed — wrong admin credentials or corrupted file.");
            }
            return plaintext;
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
                    foreach (var (name, path) in new[] {
                        ("users.json",       "/api/v1/users"),
                        ("datasources.json", "/api/v1/datasources"),
                        ("mappings.json",    "/api/v1/mappings"),
                        ("assets.json",      "/api/v1/assets"),
                        ("roles.json",       "/api/v1/roles"),
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
                    format_version = 1,
                    falconpulsar_version = "0.1.0",
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

                // Push API data (best-effort)
                var apiDir = Path.Combine(workDir, "api");
                if (Directory.Exists(apiDir))
                {
                    using var http = new HttpClient();
                    http.DefaultRequestHeaders.Authorization =
                        new AuthenticationHeaderValue("Bearer", creds.Token);
                    foreach (var (name, path) in new[] {
                        ("roles.json",       "/api/v1/roles"),
                        ("users.json",       "/api/v1/users"),
                        ("datasources.json", "/api/v1/datasources"),
                        ("assets.json",      "/api/v1/assets"),
                        ("mappings.json",    "/api/v1/mappings"),
                    })
                    {
                        var file = Path.Combine(apiDir, name);
                        if (!File.Exists(file)) continue;
                        try
                        {
                            var arr = JsonNode.Parse(await File.ReadAllTextAsync(file)) as JsonArray;
                            if (arr == null) continue;
                            foreach (var item in arr)
                            {
                                var body = new StringContent(item?.ToJsonString() ?? "{}",
                                                             Encoding.UTF8, "application/json");
                                try { await http.PostAsync($"{CoreBaseUrl}{path}", body); } catch { }
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
    }
}
