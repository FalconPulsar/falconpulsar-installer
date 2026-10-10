// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import Foundation

/// Turns the output of a failed `docker compose` run into one line a person
/// can act on, for the Start / Stop / Restart menu items. Mirrors
/// windows/tray-app/ComposeFailure.cs.
///
/// Compose prints a progress line per container and puts the reason last, for
/// example `dependency failed to start: container falconpulsar-core is
/// unhealthy`. So the LAST line that reads as an error wins; failing that, the
/// last line printed; failing that, the exit status. A reason too long to show
/// keeps its end, where the daemon puts the cause.
enum ComposeFailure {
    /// Lines containing one of these (case-insensitive) read as the reason.
    static let errorMarkers = ["error", "failed", "unhealthy", "denied", "cannot", "no such", "not found", "conflict"]

    static func summary(output: String, status: Int32, limit: Int = 240) -> String {
        // Compose colours its output when it thinks it has a terminal; the
        // daemon names endpoints by a 64-hex id that buries the cause.
        let plain = output
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ?\\([0-9a-f]{64}\\)", with: "", options: .regularExpression)
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reason = lines.last(where: { line in
            let lower = line.lowercased()
            return errorMarkers.contains { lower.contains($0) }
        }) ?? lines.last ?? "docker compose exited with status \(status)."

        // The one failure the person cannot read from compose's wording: Core
        // runs but does not answer its health check, so compose would not
        // start the services that wait for it.
        let lower = reason.lowercased()
        if lower.contains("falconpulsar-core") && lower.contains("unhealthy") {
            return "FalconPulsar Core is running but not answering, so the services that depend on it were not started. View Logs shows why."
        }
        // Too long: keep the END, where the daemon puts the cause ("…: port is
        // already allocated").
        guard reason.count > limit else { return reason }
        return "…" + String(reason.suffix(limit - 1))
    }
}
