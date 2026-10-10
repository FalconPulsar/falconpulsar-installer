// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using FalconPulsar.Tray;

// Standalone checks for the Start / Stop / Restart failure message, with no
// external test dependencies. The same cases as
// macos/menu-bar-app/Tests/ComposeFailureTests.swift.
// Run: dotnet run --project windows/tests/compose-failure
internal static class Program
{
    private static int passed;
    private static int failed;

    private static int Main()
    {
        // Verbatim from `docker compose up -d` against a Core that does not
        // answer its health check (CRLF, as wsl.exe hands it over).
        string unhealthy =
            " Container falconpulsar-core  Running\r\n" +
            " Container falconpulsar-core  Waiting\r\n" +
            " Container falconpulsar-core  Error dependency core failed to start\r\n" +
            "dependency failed to start: container falconpulsar-core is unhealthy\r\n";
        Check("unhealthy Core is explained in plain words",
              ComposeFailure.Summary(unhealthy, 1).StartsWith("FalconPulsar Core is running but not answering"));

        Check("the last error line wins over later progress",
              ComposeFailure.Summary("Error response from daemon: pull access denied for falconpulsar/nope\n Container falconpulsar-ui  Started\n", 1)
              == "Error response from daemon: pull access denied for falconpulsar/nope");

        Check("colour codes are stripped",
              ComposeFailure.Summary("\u001b[31mError\u001b[0m port is already allocated\n", 1) == "Error port is already allocated");

        Check("no error word falls back to the last line",
              ComposeFailure.Summary("one\ntwo\n\n", 1) == "two");

        Check("no output names the exit code",
              ComposeFailure.Summary("  \r\n", 125) == "docker compose exited with code 125.");

        string truncated = ComposeFailure.Summary("error: " + new string('x', 500) + " the cause", 1, 40);
        Check("a long reason keeps its end", truncated.Length == 40 && truncated.StartsWith("…") && truncated.EndsWith("the cause"));

        string id = string.Concat(System.Linq.Enumerable.Repeat("f600fb88", 8));
        string port = ComposeFailure.Summary("Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint falconpulsar-core (" + id + "): Bind for 0.0.0.0:7433 failed: port is already allocated\n", 1);
        Check("a port conflict keeps its cause", port.EndsWith("Bind for 0.0.0.0:7433 failed: port is already allocated") && !port.Contains(id));

        // wsl.exe writes its own errors as UTF-16LE; read as UTF-8 that is a
        // NUL after every character.
        string utf16 = System.Text.Encoding.UTF8.GetString(System.Text.Encoding.Unicode.GetBytes(
            "There is no distribution with the supplied name.\r\nError code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND\r\n"));
        Check("a wsl.exe error in UTF-16 reads as text",
              ComposeFailure.Summary(utf16, -1) == "Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND");

        Check("a balloon never gets more than 255 characters",
              ComposeFailure.Summary("error: " + new string('y', 1000), 1).Length <= 255);

        const string gateway = "dependency failed to start: container falconpulsar-ai-gateway is unhealthy";
        Check("another unhealthy container is not called Core",
              ComposeFailure.Summary(gateway, 1) == gateway);

        Console.WriteLine($"{passed} passed, {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static void Check(string name, bool ok)
    {
        if (ok) { passed++; Console.WriteLine("ok   " + name); }
        else { failed++; Console.WriteLine("FAIL " + name); }
    }
}
