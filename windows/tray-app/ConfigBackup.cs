// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Collections.Generic;
using System.Diagnostics;
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
    //    files/{ai_config.db,ssr.db,knowledge.db,watches.db,db_fp-agentics.db,
    //           command-center.db}  ← the AI stack's configuration stores; the
    //         entry name is "files/" + the path relative to the service's data
    //         dir with "/" replaced by "_".
    //    api/{roles,users,asset-types,assets,datasources,series,mappings,
    //         relationships,annotations}.json
    //    api/config-bundle.json  ← GET /api/v1/admin/config-bundle (new in v3):
    //         the complete-server secrets — user password hashes+salts, MFA
    //         secrets, API-token records, roles, layout/favorite/label/
    //         preference KV, and the UNMASKED datasource configs. Its bytes are
    //         POSTed back verbatim and applied first on import; only the
    //         datasource_secrets section is read out of it, after the
    //         datasources have been created.
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

        /// <summary>
        /// The archive was written but does not hold everything it was asked to
        /// collect. The file is still usable for whatever it did capture, so
        /// this is deliberately not a plain failure — but the caller must say
        /// INCOMPLETE and name the gaps, never "Export complete".
        /// </summary>
        public class IncompleteExportException : BackupException
        {
            public string Written { get; }
            public List<string> Problems { get; }

            public IncompleteExportException(string written, List<string> problems)
                : base($"Backup written to {written} but INCOMPLETE — {problems.Count} section(s) missing: "
                       + string.Join("; ", problems))
            {
                Written = written;
                Problems = problems;
            }
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

        // WSL distro hosting the stack, set by TrayApp alongside
        // FalconPulsarHomeDir. The AI configuration stores live inside the
        // distro: Windows reads them over \\wsl.localhost\<distro>, and they are
        // snapshotted through `wsl.exe -d <distro> -- docker exec`. Empty means
        // "no distro known", which leaves every store unresolved (and therefore
        // skipped) rather than guessing at a path.
        public static string WslDistro { get; set; } = "";

        // ---- AI configuration stores ----
        //
        // AI configuration lives outside Core entirely — the gateway's
        // providers, models and (Fernet-encrypted) API keys, its semantic
        // registry and terminology packs, the engine's agents / reports /
        // notification channels, Command Center's own store. None of it is
        // reachable through the Core REST API. This list, and the archive names
        // it produces, mirror ConfigStores() in
        // console/internal/databackup/databackup.go; the two must stay in step
        // or an archive stops being interchangeable between platforms.

        private sealed class ConfigStore
        {
            public string Container;      // docker container that owns the writes
            public string ContainerDir;   // the data directory as the container sees it
            public string HostDir;        // the same directory as Windows sees it ("" = unresolved)
            public string Rel;            // path of the db relative to that directory
            public bool NodeRuntime;      // node:sqlite (engine, copilot) vs python sqlite3 (gateway)
        }

        // Entry names are flat: "files/" + the relative path with "/" replaced
        // by "_", so db/fp-agentics.db travels as files/db_fp-agentics.db.
        private static string StoreFileName(ConfigStore store) => store.Rel.Replace('/', '_');

        private static List<ConfigStore> ConfigStores()
        {
            var dirs = ResolveStackDataDirs();
            return new List<ConfigStore>
            {
                // providers, models, API keys, gateway settings
                new ConfigStore { Container = "falconpulsar-ai-gateway", ContainerDir = "/app/data",
                                  HostDir = dirs.gateway, Rel = "ai_config.db" },
                // semantic registry + terminology packs — declared by hand, expensive to lose
                new ConfigStore { Container = "falconpulsar-ai-gateway", ContainerDir = "/app/data",
                                  HostDir = dirs.gateway, Rel = "ssr.db" },
                // user-authored knowledge documents
                new ConfigStore { Container = "falconpulsar-ai-gateway", ContainerDir = "/app/data",
                                  HostDir = dirs.gateway, Rel = "knowledge.db" },
                // Watches are authored by a person and say what the plant should
                // keep an eye on — configuration, not history, even though the
                // same file also holds each watch's last stored snapshot.
                new ConfigStore { Container = "falconpulsar-ai-gateway", ContainerDir = "/app/data",
                                  HostDir = dirs.gateway, Rel = "watches.db" },
                // agents, specs, reports, notification channels, schedules
                new ConfigStore { Container = "falconpulsar-ai-engine", ContainerDir = "/data",
                                  HostDir = dirs.engine, Rel = "db/fp-agentics.db", NodeRuntime = true },
                new ConfigStore { Container = "falconpulsar-copilot", ContainerDir = "/data",
                                  HostDir = dirs.copilot, Rel = "command-center.db", NodeRuntime = true },
            };
        }

        // Where those stores actually live. FP_*_DATA_DIR are supported
        // relocations, and looking for them under a hardcoded ai-gateway-data
        // meant a relocated stack exported no AI configuration at all while
        // still reporting success. The defaults are compose.yml's, which hang
        // off FP_DATA_DIR's parent. Every path in .env is a path INSIDE the
        // distro, so each is mapped onto \\wsl.localhost\<distro> to be read
        // from Windows.
        private static (string gateway, string engine, string copilot) ResolveStackDataDirs()
        {
            var vals = ReadEnvValues(Path.Combine(FalconPulsarHomeDir, ".env"), new[] {
                "FP_HOME", "FP_DATA_DIR",
                "FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR", "FP_COPILOT_DATA_DIR",
            });
            string Value(string key) =>
                vals.TryGetValue(key, out var v) ? v.Trim().Trim('"', '\'') : "";

            var coreDir = Value("FP_DATA_DIR");
            if (coreDir.Length == 0)
            {
                var fpHome = Value("FP_HOME");
                if (fpHome.Length > 0) coreDir = fpHome + "/data";
            }
            if (coreDir.Length == 0) return ("", "", "");   // no readable .env — nothing to resolve

            var parent = LinuxParentDir(coreDir);
            string Dir(string key, string fallback)
            {
                var v = Value(key);
                return HostPathForLinuxPath(v.Length > 0 ? v : fallback);
            }
            return (Dir("FP_GATEWAY_DATA_DIR", parent + "/ai-gateway-data"),
                    Dir("FP_ENGINE_DATA_DIR",  parent + "/ai-engine-data"),
                    Dir("FP_COPILOT_DATA_DIR", parent + "/copilot-data"));
        }

        // Parent of a LINUX path ("/home/u/falconpulsar/data" ->
        // "/home/u/falconpulsar"). Path.GetDirectoryName would rewrite the
        // separators as Windows ones, which is not what compose reads.
        private static string LinuxParentDir(string path)
        {
            var trimmed = path.TrimEnd('/');
            int slash = trimmed.LastIndexOf('/');
            return slash > 0 ? trimmed.Substring(0, slash) : "/";
        }

        // A path inside the distro as Windows sees it — the same mapping
        // TrayApp applies to the install directory when it sets
        // FalconPulsarHomeDir.
        private static string HostPathForLinuxPath(string path)
        {
            if (string.IsNullOrEmpty(path) || path[0] != '/') return "";
            if (!IsValidDistroName(WslDistro)) return "";
            return $@"\\wsl.localhost\{WslDistro}" + path.Replace('/', '\\');
        }

        // The distro name is interpolated into a UNC path and into wsl.exe's
        // command line, so anything outside the documented alphanumeric +
        // dot/underscore/hyphen set is refused rather than passed through
        // (mirrors TrayApp.IsValidDistroName).
        private static bool IsValidDistroName(string distro)
        {
            if (string.IsNullOrEmpty(distro)) return false;
            foreach (var c in distro)
            {
                bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                          || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
                if (!ok) return false;
            }
            return true;
        }

        /// <summary>
        /// Writes a consistent copy of one store to <paramref name="hostDst"/>.
        ///
        /// This has to go through VACUUM INTO inside the owning container,
        /// never a host-side file copy: every one of these databases is opened
        /// WAL, so recent commits can live entirely in the -wal sidecar.
        /// Reading the main file alone yields a database missing them — or, if
        /// it is caught mid-checkpoint, one that is internally inconsistent.
        ///
        /// Returns false when the store is not installed here; that is not an
        /// error, there is simply nothing to capture. Throws when the store
        /// exists but could not be copied.
        /// </summary>
        private static async Task<bool> SnapshotConfigStoreAsync(ConfigStore store, string hostDst)
        {
            if (string.IsNullOrEmpty(store.HostDir)) return false;
            var src = Path.Combine(store.HostDir, store.Rel.Replace('/', '\\'));
            if (!File.Exists(src)) return false;    // store not present on this install
            if (!await IsContainerRunningAsync(store.Container))
                throw new BackupException(
                    $"{store.Container} is not running, so {store.Rel} cannot be snapshotted consistently");

            // VACUUM INTO refuses to overwrite, so the destination must not
            // exist. Write beside the source — inside the volume, the only
            // place the container can write — and move it out afterwards.
            var tmpRel = store.Rel + ".fpconfig-snapshot";
            var tmpHost = Path.Combine(store.HostDir, tmpRel.Replace('/', '\\'));
            try { File.Delete(tmpHost); } catch { }
            try
            {
                var (exitCode, output) = await RunInDistroAsync(
                    $"docker exec {ShellQuote(store.Container)} {VacuumCommand(store, tmpRel)}");
                if (exitCode != 0)
                    throw new BackupException($"snapshot {store.Rel}: {OneLine(output)}");
                File.Copy(tmpHost, hostDst, overwrite: true);
            }
            finally
            {
                try { File.Delete(tmpHost); } catch { }
            }
            return true;
        }

        // The same one-liners console/internal/databackup runs: the gateway
        // image carries python, the engine and Command Center images carry node
        // with node:sqlite. Both write the snapshot inside the container's own
        // volume, which is what makes it readable from the host afterwards.
        private static string VacuumCommand(ConfigStore store, string relDst)
        {
            var src = store.ContainerDir + "/" + store.Rel;
            var dst = SqlQuote(store.ContainerDir + "/" + relDst);
            if (store.NodeRuntime)
                return "node -e " + ShellQuote(
                    "const {DatabaseSync}=require('node:sqlite'); "
                    + $"new DatabaseSync(\"{src}\").exec(\"VACUUM INTO {dst}\")");
            return "python -c " + ShellQuote(
                $"import sqlite3; sqlite3.connect(\"{src}\").execute(\"VACUUM INTO {dst}\")");
        }

        private static async Task<bool> IsContainerRunningAsync(string container)
        {
            var (exitCode, output) = await RunInDistroAsync(
                $"docker inspect -f '{{{{.State.Running}}}}' {ShellQuote(container)} 2>/dev/null");
            return exitCode == 0 && output.Trim() == "true";
        }

        // Runs a bash script inside the distro as its default user — the user
        // that owns the stack in per-user installs, and the one Docker Desktop's
        // WSL integration puts `docker` on the PATH for. The script is piped in
        // rather than passed as arguments so quoting survives wsl.exe's own
        // command-line parsing (mirrors TrayApp.RunWslBashCaptureAsync).
        private static async Task<(int exitCode, string output)> RunInDistroAsync(string script)
        {
            if (!IsValidDistroName(WslDistro)) return (-1, "no WSL distro configured");
            var psi = new ProcessStartInfo
            {
                FileName = "wsl.exe",
                Arguments = $"-d {WslDistro} -- bash",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // Force UTF-8 on stdin. .NET otherwise encodes the piped script
                // in the Windows OEM codepage and bash sees mangled bytes.
                StandardInputEncoding = new UTF8Encoding(false),
            };
            using var proc = Process.Start(psi);
            if (proc == null) return (-1, "could not start wsl.exe");
            await proc.StandardInput.WriteAsync(script);
            proc.StandardInput.Close();
            // Both pipes are drained before waiting: a container that writes a
            // long traceback to stderr would otherwise fill its buffer and
            // deadlock against WaitForExit.
            var stdout = proc.StandardOutput.ReadToEndAsync();
            var stderr = proc.StandardError.ReadToEndAsync();
            await Task.WhenAll(stdout, stderr);
            await proc.WaitForExitAsync();
            return (proc.ExitCode, (stdout.Result + stderr.Result).Trim());
        }

        // Single-quoted SQL string literal.
        private static string SqlQuote(string value) => "'" + value.Replace("'", "''") + "'";

        // Single-quoted bash word. The script is piped to a shell, so every
        // interpolated value is quoted rather than trusted.
        private static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";

        // Docker, python and node all fail with multi-line output; the export
        // report lists one line per problem, so flatten and cap it.
        private static string OneLine(string output)
        {
            var flat = (output ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (flat.Length == 0) return "docker exec failed";
            return flat.Length > 300 ? flat.Substring(0, 300) + "…" : flat;
        }

        public static async Task ExportAsync(string outputPath, AdminCredentials creds)
        {
            var workDir = Path.Combine(Path.GetTempPath(), "fpconfig-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDir);

            // What went wrong, and what was actually captured. The manifest used
            // to be a fixed set of fields, and a section that failed to harvest
            // was replaced by an empty stub — which made a backup that silently
            // contained no datasources indistinguishable from one taken on a
            // stack that has none. These accumulate and the manifest is written
            // from them at the end.
            var problems = new List<string>();
            var capturedSections = new List<string>();
            var capturedStores = new List<string>();
            bool bundleCaptured = false;
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
                // The AI stack's configuration stores. Snapshotted through the
                // owning container (see SnapshotConfigStoreAsync) rather than
                // copied off the host: they are all WAL databases, so a plain
                // file read misses everything still sitting in the -wal sidecar.
                // Provider keys stay Fernet-encrypted with FP_GATEWAY_SECRET,
                // which travels in the restored .env.
                foreach (var store in ConfigStores())
                {
                    try
                    {
                        if (await SnapshotConfigStoreAsync(store, Path.Combine(filesDir, StoreFileName(store))))
                            capturedStores.Add(store.Rel);
                    }
                    catch (Exception ex)
                    {
                        // A store that exists but could not be snapshotted is a
                        // hole in the backup. Record it so the archive cannot
                        // pass for complete.
                        problems.Add($"{store.Rel}: {ex.Message}");
                    }
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
                            capturedSections.Add(sec.key);
                        }
                        catch (Exception ex)
                        {
                            // A section that failed to harvest is NOT written at
                            // all. An empty stub made "the server refused this
                            // endpoint" look exactly like "this stack has none of
                            // these", so a backup missing every datasource
                            // imported cleanly and produced an empty plant.
                            // Import treats an absent section as "not in this
                            // archive" and leaves the target's own data alone.
                            problems.Add($"{sec.key}: {ex.Message}");
                        }
                    }

                    // v3: the complete server bundle — password hashes, MFA
                    // secrets, API tokens, roles, layouts, favorites, labels,
                    // preferences, and the unmasked datasource configs. This is
                    // the ONLY source of the secrets a real "restore a server"
                    // needs; the whole backup is AES-encrypted so these never
                    // touch disk in the clear. This is the LAST api/* entry added
                    // before the zip is created.
                    try
                    {
                        using var bundleResp = await http.GetAsync(
                            $"{CoreBaseUrl}/api/v1/admin/config-bundle");
                        if (bundleResp.IsSuccessStatusCode)
                        {
                            var bundle = await bundleResp.Content.ReadAsByteArrayAsync();
                            if (bundle.Length > 0)
                            {
                                File.WriteAllBytes(
                                    Path.Combine(apiDir, "config-bundle.json"), bundle);
                                bundleCaptured = true;
                            }
                        }
                        else
                        {
                            // Without the bundle there are no password hashes and
                            // no datasource credentials — a materially incomplete
                            // backup, not a detail. A Core too old to expose the
                            // endpoint answers 404 and lands here too.
                            problems.Add($"config-bundle: HTTP {(int)bundleResp.StatusCode}");
                        }
                    }
                    catch (Exception ex)
                    {
                        problems.Add("config-bundle: " + ex.Message);
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
                // Built LAST so it states what this archive actually contains
                // rather than what the export set out to collect.
                var manifest = new
                {
                    format_version = (int)FormatVersion,
                    falconpulsar_version = asmVersion,
                    exported_at = DateTime.UtcNow.ToString("o"),
                    source_host = Environment.MachineName,
                    source_platform = "Windows",
                    sections = capturedSections,
                    config_stores = capturedStores,
                    bundle = bundleCaptured,
                    incomplete = problems.Count > 0,
                    errors = problems
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

                // The file is written either way — a partial backup beats none —
                // but the caller must not be told this succeeded. Silence here is
                // what let an export missing whole sections pass for a complete
                // one.
                if (problems.Count > 0)
                    throw new IncompleteExportException(outputPath, problems);
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
            // FP_HOME is the install directory itself, written as an absolute
            // host path by every installer. compose.yml mounts
            // ${FP_HOME}/nginx.conf into the ui and ${FP_HOME}/auth-policy.json
            // into copilot, so carrying the backup's value onto a host that
            // installed somewhere else points both bind mounts at a path that
            // does not exist — and Docker answers a missing bind source by
            // CREATING a root-owned directory where a file belongs.
            "FP_HOME",
            "FP_DATA_DIR", "FP_GATEWAY_DATA_DIR", "FP_ENGINE_DATA_DIR", "FP_COPILOT_DATA_DIR",
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
            // CoreBaseUrl re-reads FP_REST_PORT from the stack's .env on every
            // call, and this import OVERWRITES that .env partway through — so a
            // backup carrying a different port would send everything after that
            // point at a dead one. Resolve it once, here, and use this value for
            // the whole run.
            var baseUrl = CoreBaseUrl;
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

                    // AI configuration stores → back into their real volumes, so
                    // providers, models, encrypted keys, the semantic registry
                    // and the engine's agents / reports / notification channels
                    // all come back. Resolved AFTER the .env fix-up above, so the
                    // destinations are this host's directories and not the
                    // backup's.
                    //
                    // Two things this has to get right:
                    //   * the destination comes from .env, not a hardcoded
                    //     ai-gateway-data — otherwise a relocated stack restores
                    //     into a directory nothing reads;
                    //   * the -wal and -shm sidecars beside the destination MUST
                    //     be removed. The file is replaced underneath a running
                    //     container, and a stale WAL belonging to the OLD
                    //     database would either be replayed over the restored one
                    //     (silently reverting it) or rejected as corrupt.
                    // These land while the stack is up; the "Restart Stack"
                    // prompt after import is when the containers re-open them.
                    foreach (var store in ConfigStores())
                    {
                        var storeSrc = Path.Combine(filesDir, StoreFileName(store));
                        if (!File.Exists(storeSrc)) continue;
                        if (string.IsNullOrEmpty(store.HostDir)) continue;
                        var storeDst = Path.Combine(store.HostDir, store.Rel.Replace('/', '\\'));
                        var storeDstDir = Path.GetDirectoryName(storeDst);
                        if (!string.IsNullOrEmpty(storeDstDir))
                            Directory.CreateDirectory(storeDstDir);
                        File.Copy(storeSrc, storeDst, overwrite: true);
                        foreach (var sidecar in new[] { storeDst + "-wal", storeDst + "-shm" })
                        {
                            try { File.Delete(sidecar); }
                            catch (Exception ex)
                            {
                                throw new BackupException(
                                    $"Could not remove the stale {Path.GetFileName(sidecar)} " +
                                    $"({ex.Message}) — the restored {store.Rel} would be unreadable.");
                            }
                        }
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
                    // password-less REST create path. Its bytes are POSTed
                    // verbatim; the bundle is kept because the datasource secrets
                    // are read out of it once the datasources exist.
                    bool bundleApplied = false;
                    byte[] bundleBytes = null;
                    var bundleFile = Path.Combine(apiDir, "config-bundle.json");
                    if (File.Exists(bundleFile))
                    {
                        try
                        {
                            bundleBytes = await File.ReadAllBytesAsync(bundleFile);
                            var bundleBody = new ByteArrayContent(bundleBytes);
                            bundleBody.Headers.ContentType =
                                new MediaTypeHeaderValue("application/json");
                            var bundleResp = await http.PostAsync(
                                $"{baseUrl}/api/v1/admin/config-bundle", bundleBody);
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
                                await ImportSeriesBulkAsync(http, baseUrl, items);
                                continue;
                            }
                            if (sec.key == "assets")
                            {
                                // GET /api/v1/assets walks the metadata B-tree in
                                // sorted BYTE order over "_asset/id/<decimal>", so
                                // id 100 comes back before id 95. Restored in that
                                // order a child can be POSTed before its parent;
                                // Core then auto-creates the parent as a bare
                                // placeholder, and the real parent's own POST comes
                                // back 409 and is counted as a skip — losing its
                                // asset_type, properties and status silently.
                                items = OrderAssetsParentsFirst(items);
                            }
                            foreach (var raw in items)
                            {
                                var stripped = StripServerIDs(raw);
                                if (sec.key == "datasources" && stripped["config"] is JsonObject dsConfig)
                                {
                                    // GET /api/v1/datasources masks password /
                                    // token / client_key / private_key, and the
                                    // create handler has no unmask step — POSTing
                                    // this straight through would store the mask AS
                                    // the credential, leaving a datasource that
                                    // looks configured and cannot authenticate.
                                    // RestoreDatasourceSecretsAsync puts the real
                                    // values back from the admin bundle below.
                                    StripMaskedSecrets(dsConfig);
                                }
                                var body = new StringContent(stripped.ToJsonString(),
                                                             Encoding.UTF8, "application/json");
                                // Count (don't swallow) a server rejection so the tray
                                // can warn — a rejected datasource/mapping leaves dead
                                // series. PostAsync does NOT throw on 4xx/5xx, so the
                                // status check is what actually catches it.
                                try
                                {
                                    var resp = await http.PostAsync($"{baseUrl}{sec.path}", body);
                                    if (!resp.IsSuccessStatusCode && (int)resp.StatusCode != 409)
                                        LastImportErrorCount++;
                                }
                                catch { LastImportErrorCount++; }
                            }
                        }
                        catch { /* skip malformed */ }
                    }

                    // The datasources were created without their secrets (the
                    // public export masks them). Put the real credentials back
                    // now that the rows exist.
                    await RestoreDatasourceSecretsAsync(http, baseUrl, bundleBytes);
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
        /// Throws when the FIRST page fails: the caller records that section as
        /// missing rather than writing an empty stub, which would be
        /// indistinguishable from a stack that genuinely has none.
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
        private static async Task ImportSeriesBulkAsync(
            HttpClient http, string baseUrl, IEnumerable<JsonObject> items)
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
                    await PostSeriesBatchAsync(http, baseUrl, batch);
                    batch = new JsonArray();
                }
            }
            if (batch.Count > 0) await PostSeriesBatchAsync(http, baseUrl, batch);
        }

        private static async Task PostSeriesBatchAsync(HttpClient http, string baseUrl, JsonArray batch)
        {
            var payload = new JsonObject { ["series"] = batch };
            var body = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
            try
            {
                var resp = await http.PostAsync($"{baseUrl}/api/v1/series/bulk", body);
                if (!resp.IsSuccessStatusCode && (int)resp.StatusCode != 409)
                    LastImportErrorCount++;
            }
            catch { LastImportErrorCount++; }
        }

        /// <summary>
        /// What Core substitutes for password / token / client_key /
        /// private_key on the public datasource endpoints (FP_SECRET_MASK in
        /// rest_common.h). It must never be written back as if it were a
        /// credential.
        /// </summary>
        private const string SecretMask = "********";

        /// <summary>Mirrors SECRET_CONFIG_KEYS in falconpulsar-core's
        /// rest_common.c. Keep the two in step.</summary>
        private static readonly string[] SecretConfigKeys =
            { "password", "token", "client_key", "private_key" };

        /// <summary>
        /// Removes the keys of a datasource config whose value is the mask, so
        /// a write never persists "********" as a real credential. Keys holding
        /// a genuine value are left alone — a backup taken from a Core old
        /// enough to return unmasked configs still restores directly.
        /// </summary>
        private static void StripMaskedSecrets(JsonObject config)
        {
            foreach (var key in SecretConfigKeys)
            {
                if (config[key] is JsonValue v && v.TryGetValue<string>(out var s) && s == SecretMask)
                    config.Remove(key);
            }
        }

        /// <summary>
        /// Writes the real credentials over the datasources the create pass just
        /// made from the masked public export. The values come from
        /// GET /api/v1/admin/config-bundle — the admin-only channel that already
        /// carries password hashes and MFA secrets — and the archive as a whole
        /// is encrypted.
        ///
        /// Matched by NAME, not id: the target mints its own ids. An archive
        /// with no datasource_secrets (v1/v2, or one taken from a Core that
        /// predates the section) is a no-op.
        /// </summary>
        private static async Task RestoreDatasourceSecretsAsync(
            HttpClient http, string baseUrl, byte[] bundleBytes)
        {
            if (bundleBytes == null || bundleBytes.Length == 0) return;
            JsonNode bundle;
            try { bundle = JsonNode.Parse(Encoding.UTF8.GetString(bundleBytes)); }
            catch { return; }
            if (bundle is not JsonObject bundleObj) return;
            if (bundleObj["datasource_secrets"] is not JsonArray secrets || secrets.Count == 0) return;

            // Resolve name -> id on the target.
            var idByName = new Dictionary<string, string>();
            try
            {
                var listResp = await http.GetAsync($"{baseUrl}/api/v1/datasources");
                if (listResp.IsSuccessStatusCode)
                {
                    foreach (var ds in ExtractItems(
                                 await listResp.Content.ReadAsStringAsync(), "datasources"))
                    {
                        var name = ds["name"]?.ToString();
                        var id = ds["id"]?.ToString();
                        if (!string.IsNullOrEmpty(name) && IsDecimal(id))
                            idByName[name] = id;
                    }
                }
            }
            catch { /* nothing resolves below, and each secret is then skipped */ }

            foreach (var node in secrets)
            {
                if (node is not JsonObject secret) continue;
                var name = secret["name"]?.ToString();
                if (string.IsNullOrEmpty(name)) continue;
                // A datasource that isn't on the target failed to import; its
                // secret has nowhere to go, and that failure was already counted
                // in the datasources section.
                if (!idByName.TryGetValue(name, out var id)) continue;
                if (secret["config"] is not JsonObject rawConfig) continue;

                var config = (JsonObject)rawConfig.DeepClone();
                StripMaskedSecrets(config);   // never write the mask, even from the bundle
                var payload = new JsonObject { ["config"] = config };
                var body = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
                try
                {
                    // PATCH, not PUT: Core routes PUT /api/v1/datasources/<id> only to
                    // the mqtt/subscriptions subpath and answers anything else with
                    // "Unknown datasource PUT action". The config update is the PATCH
                    // handler, so a PUT here would 400 and leave every restored
                    // datasource with no credential at all.
                    using var patch = new HttpRequestMessage(
                        new HttpMethod("PATCH"), $"{baseUrl}/api/v1/datasources/{id}")
                    {
                        Content = body,
                    };
                    var resp = await http.SendAsync(patch);
                    if (!resp.IsSuccessStatusCode) LastImportErrorCount++;
                }
                catch { LastImportErrorCount++; }
            }
        }

        // Ids are interpolated into a URL path, so accept only the decimal form
        // Core actually issues.
        private static bool IsDecimal(string value)
        {
            if (string.IsNullOrEmpty(value)) return false;
            foreach (var c in value)
                if (c < '0' || c > '9') return false;
            return true;
        }

        /// <summary>
        /// Sorts assets so every asset is preceded by its ancestors, using the
        /// hierarchy path rather than the id.
        ///
        /// Ordering by id does not work: Core returns assets in sorted BYTE
        /// order over "_asset/id/&lt;decimal&gt;", so "100" sorts before "95".
        /// Ordering by path DEPTH does, because a parent's path is always a
        /// proper prefix of its children's and therefore strictly shallower.
        /// Siblings keep their original relative order, so a restore is
        /// reproducible; assets with no usable path keep theirs and go last,
        /// since nothing can be known about their placement.
        /// </summary>
        private static List<JsonObject> OrderAssetsParentsFirst(IEnumerable<JsonObject> items)
        {
            var withPath = new List<JsonObject>();
            var depths = new List<int>();
            var withoutPath = new List<JsonObject>();
            int maxDepth = 0;
            foreach (var item in items)
            {
                int depth = AssetPathDepth(item);
                if (depth < 0) { withoutPath.Add(item); continue; }
                withPath.Add(item);
                depths.Add(depth);
                if (depth > maxDepth) maxDepth = depth;
            }
            // Bucketing by depth in input order is a stable sort, and stability
            // is the point: a comparison sort would shuffle siblings.
            var ordered = new List<JsonObject>(withPath.Count + withoutPath.Count);
            for (int d = 0; d <= maxDepth; d++)
                for (int i = 0; i < withPath.Count; i++)
                    if (depths[i] == d) ordered.Add(withPath[i]);
            ordered.AddRange(withoutPath);
            return ordered;
        }

        // Depth of an asset's "path" — the number of separators inside it.
        // Negative when the item carries no usable path.
        private static int AssetPathDepth(JsonObject item)
        {
            if (item["path"] is not JsonValue pv || !pv.TryGetValue<string>(out var path)
                || string.IsNullOrEmpty(path)) return -1;
            int depth = 0;
            foreach (var c in path.Trim('/'))
                if (c == '/') depth++;
            return depth;
        }
    }
}
