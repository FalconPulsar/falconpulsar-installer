// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Linq;
using System.Text.RegularExpressions;

namespace FalconPulsar.Tray
{
    /// <summary>
    /// Turns the output of a failed <c>docker compose</c> run into one line a
    /// person can act on, for the Start / Stop / Restart menu items. Mirrors
    /// macos/menu-bar-app/FalconPulsar/ComposeFailure.swift.
    ///
    /// Compose prints a progress line per container and puts the reason last,
    /// for example "dependency failed to start: container falconpulsar-core is
    /// unhealthy". So the LAST line that reads as an error wins; failing that,
    /// the last line printed; failing that, the exit code. A reason too long
    /// to show keeps its end, where the daemon puts the cause. No Windows Forms
    /// here, so windows/tests/compose-failure can compile it on any OS.
    /// </summary>
    internal static class ComposeFailure
    {
        internal static readonly string[] ErrorMarkers =
            { "error", "failed", "unhealthy", "denied", "cannot", "no such", "not found", "conflict" };

        private static readonly Regex Ansi = new Regex(@"\x1B\[[0-9;?]*[A-Za-z]");
        // The daemon names endpoints by a 64-hex id that buries the cause.
        private static readonly Regex EndpointId = new Regex(@" ?\([0-9a-f]{64}\)");

        // A balloon tip holds at most 255 characters.
        internal static string Summary(string output, int exitCode, int limit = 240)
        {
            // wsl.exe's own errors (no such distro, WSL service down) reach a
            // redirected pipe as UTF-16LE and decode with a NUL between every
            // character; strip those and any BOM, as ReadWslHome does.
            var text = (output ?? string.Empty).Replace("\0", string.Empty).Replace("\uFEFF", string.Empty);
            var lines = EndpointId.Replace(Ansi.Replace(text, string.Empty), string.Empty)
                .Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .ToList();
            var reason = lines.LastOrDefault(l =>
                             ErrorMarkers.Any(m => l.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0))
                         ?? lines.LastOrDefault()
                         ?? $"docker compose exited with code {exitCode}.";

            // The one failure the person cannot read from compose's wording:
            // Core runs but does not answer its health check, so compose would
            // not start the services that wait for it.
            if (reason.IndexOf("falconpulsar-core", StringComparison.OrdinalIgnoreCase) >= 0
                && reason.IndexOf("unhealthy", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "FalconPulsar Core is running but not answering, so the services that depend on it were not started. View Logs shows why.";
            }
            // Too long: keep the END, where the daemon puts the cause ("…: port
            // is already allocated").
            return reason.Length <= limit ? reason : "…" + reason.Substring(reason.Length - (limit - 1));
        }
    }
}
