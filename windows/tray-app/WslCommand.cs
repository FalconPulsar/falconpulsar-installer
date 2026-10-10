// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace FalconPulsar.Tray
{
    /// <summary>
    /// Runs a command through wsl.exe with a deadline that holds on BOTH sides.
    /// </summary>
    /// <remarks>
    /// Killing wsl.exe, even with its whole Windows process tree, ends the
    /// Windows side only. The docker client it started is a Linux process
    /// inside the distro, outside that tree, and against a wedged daemon it
    /// went on waiting: every 15 s poll could leave one more hung client
    /// behind. So a command with a deadline is wrapped in coreutils `timeout`,
    /// which ends it and its process group inside the distro a little before
    /// the Windows deadline. The Windows kill stays, as the backstop for
    /// wsl.exe or the distro itself not answering.
    ///
    /// No Windows Forms here, so windows/tests/wsl-deadline compiles and runs
    /// this file on any OS.
    /// </remarks>
    internal static class WslCommand
    {
        /// <summary>After its SIGTERM, how long `timeout` waits before SIGKILL.</summary>
        public const int KillAfterSeconds = 2;

        /// <summary>
        /// The Linux deadline under a Windows one: it leaves the SIGKILL grace
        /// and one more second for wsl.exe to carry the exit back, so the
        /// Linux side has ended its command before Windows gives up.
        /// </summary>
        public static int LinuxSeconds(int windowsSeconds) =>
            Math.Max(1, windowsSeconds - KillAfterSeconds - 1);

        /// <summary>
        /// `timeout -k 2 &lt;n&gt; &lt;command&gt;`, for the Linux side of a
        /// command whose Windows deadline is <paramref name="windowsSeconds"/>.
        /// Every distro the installer accepts (Ubuntu, Debian, RHEL family,
        /// Fedora, openSUSE) ships GNU coreutils, which has it.
        /// </summary>
        public static string Bounded(string command, int windowsSeconds) =>
            $"timeout -k {KillAfterSeconds} {LinuxSeconds(windowsSeconds)} {command}";

        /// <summary>
        /// How `timeout` says it ended the command: 124 when SIGTERM did it,
        /// 137 (128 + SIGKILL) when the command outlived that and the kill
        /// took the whole group. wsl.exe passes the code through.
        /// </summary>
        public static bool LinuxTimedOut(int exitCode) => exitCode == 124 || exitCode == 137;

        /// <summary>
        /// Starts <paramref name="fileName"/> (wsl.exe in the tray), feeds it
        /// <paramref name="stdin"/> when given, and reads both streams while
        /// it runs: reading one only after exit can deadlock on a full pipe.
        /// </summary>
        /// <param name="timeoutSeconds">
        /// 0 waits for as long as the command runs. Otherwise, past the
        /// deadline the process tree is killed, and the result is timedOut
        /// with no output; so is an exit that reads as <see cref="LinuxTimedOut"/>,
        /// since the command line is expected to carry <see cref="Bounded"/>.
        /// </param>
        /// <exception cref="System.ComponentModel.Win32Exception">The program could not be started.</exception>
        public static async Task<(int exitCode, string stdout, bool timedOut)> RunAsync(
            string fileName, string arguments, string stdin, int timeoutSeconds)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            if (stdin != null)
            {
                psi.RedirectStandardInput = true;
                // Force UTF-8 on stdin. Without this, .NET defaults to the
                // Windows OEM codepage (CP1252 on en-US). Non-ASCII bytes
                // in the piped bash script (e.g. em-dashes in progress
                // messages) get transliterated to single CP1252 bytes
                // (0x97 for em-dash) and bash writes those verbatim,
                // corrupting anything the script echoes into a file.
                psi.StandardInputEncoding = new System.Text.UTF8Encoding(false);
            }
            using var proc = Process.Start(psi);
            if (proc == null) return (-1, string.Empty, false);
            if (stdin != null)
            {
                await proc.StandardInput.WriteAsync(stdin);
                proc.StandardInput.Close();
            }
            var stdoutTask = proc.StandardOutput.ReadToEndAsync();
            var stderrTask = proc.StandardError.ReadToEndAsync();
            if (timeoutSeconds > 0)
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
                try
                {
                    await proc.WaitForExitAsync(cts.Token);
                }
                catch (OperationCanceledException)
                {
                    try { proc.Kill(entireProcessTree: true); } catch { }
                    return (-1, string.Empty, true);
                }
            }
            else
            {
                await proc.WaitForExitAsync();
            }
            await stderrTask;
            if (timeoutSeconds > 0 && LinuxTimedOut(proc.ExitCode))
            {
                return (proc.ExitCode, string.Empty, true);
            }
            return (proc.ExitCode, await stdoutTask, false);
        }
    }
}
