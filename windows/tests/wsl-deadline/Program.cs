// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using FalconPulsar.Tray;

// Standalone checks for the tray's WSL deadline (WslCommand), with no external
// test dependencies. /bin/sh stands in for wsl.exe: what is under test is the
// runner and the `timeout` wrap, not WSL. The checks that need GNU `timeout`
// run where it exists (Linux, or inside a WSL distro) and say "skip" elsewhere;
// macOS does not ship it.
// Run: dotnet run --project windows/tests/wsl-deadline
internal static class Program
{
    private static int passed;
    private static int failed;
    private static int skipped;

    private static async Task<int> Main()
    {
        Pure();
        Wiring();
        if (OperatingSystem.IsWindows())
        {
            Skip("runner checks", "they use /bin/sh");
        }
        else
        {
            await Runner();
            if (await HasGnuTimeout())
            {
                await LinuxSide();
            }
            else
            {
                Skip("the Linux side ends a hung command before Windows does", "no GNU timeout on PATH");
                Skip("a command that ignores SIGTERM is killed with its group", "no GNU timeout on PATH");
            }
        }

        Console.WriteLine($"{passed} passed, {failed} failed, {skipped} skipped");
        return failed == 0 ? 0 : 1;
    }

    private static void Pure()
    {
        // The probes' 15 s and the .env read's 15 s, and About's 10 s.
        foreach (int windows in new[] { 10, 15 })
        {
            Check($"the Linux side is done, SIGKILL included, before the {windows} s Windows deadline",
                  WslCommand.LinuxSeconds(windows) + WslCommand.KillAfterSeconds < windows);
        }

        Check("a probe's command line is timeout -k 2 12 <command>",
              WslCommand.Bounded("docker ps --filter name=falconpulsar-core --filter status=running -q", 15)
              == "timeout -k 2 12 docker ps --filter name=falconpulsar-core --filter status=running -q");

        Check("a tiny deadline still gives the command a second",
              WslCommand.LinuxSeconds(1) == 1 && WslCommand.LinuxSeconds(3) == 1);

        Check("timeout's own exits read as timed out",
              WslCommand.LinuxTimedOut(124) && WslCommand.LinuxTimedOut(137));

        // 125: timeout itself failed. 126/127: the command could not run.
        Check("the command's own exits do not",
              !WslCommand.LinuxTimedOut(0) && !WslCommand.LinuxTimedOut(1) && !WslCommand.LinuxTimedOut(125)
              && !WslCommand.LinuxTimedOut(126) && !WslCommand.LinuxTimedOut(127));
    }

    // TrayApp.cs is Windows Forms and does not compile here, so its wiring is
    // read as text. Without this, a runner that stopped calling Bounded would
    // pass every check above while its docker client went back to outliving
    // the Windows kill.
    private static void Wiring([CallerFilePath] string here = "")
    {
        string tray = FindTraySource(here);
        if (tray == null)
        {
            Check("TrayApp.cs is found next to these checks", false);
            return;
        }
        string src = File.ReadAllText(tray);
        Check("the status probes carry the Linux-side deadline",
              src.Contains("WslCommand.Bounded(command, timeoutSeconds)"));
        Check("a bash script with a deadline carries the Linux-side deadline",
              src.Contains("WslCommand.Bounded(\"bash\", timeoutSeconds)"));
        // A runner of its own, with only the Windows-side kill, is the bug
        // this file exists for.
        Check("no other tray runner kills wsl.exe on a deadline of its own",
              !src.Contains("Kill(entireProcessTree"));
    }

    private static string FindTraySource(string here)
    {
        if (!string.IsNullOrEmpty(here))
        {
            string beside = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here), "..", "..", "tray-app", "TrayApp.cs"));
            if (File.Exists(beside)) return beside;
        }
        for (var dir = new DirectoryInfo(Environment.CurrentDirectory); dir != null; dir = dir.Parent)
        {
            string candidate = Path.Combine(dir.FullName, "windows", "tray-app", "TrayApp.cs");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static async Task Runner()
    {
        var timedOutExit = await WslCommand.RunAsync("/bin/sh", "-c \"echo partial; exit 124\"", null, 5);
        Check("under a deadline, the Linux side's 124 is a timeout with no output",
              timedOutExit == (124, string.Empty, true));

        var plainExit = await WslCommand.RunAsync("/bin/sh", "-c \"echo partial; exit 124\"", null, 0);
        Check("without a deadline, 124 is only the command's exit",
              plainExit == (124, "partial\n", false));

        // RunWslBashCaptureAsync's path: the script goes in on stdin, as UTF-8.
        var piped = await WslCommand.RunAsync("/bin/sh", "-s", "printf '%s' 'a—b'\n", 5);
        Check("a script on stdin runs and its output comes back", piped == (0, "a—b", false));

        // The Windows-side backstop: nothing inside ends the command, so the
        // kill must, with the child the shell started.
        string pidFile = Path.Combine(Path.GetTempPath(), "fp-wsl-deadline-" + Guid.NewGuid().ToString("N"));
        try
        {
            var watch = Stopwatch.StartNew();
            var hung = await WslCommand.RunAsync("/bin/sh", $"-c \"sleep 41 & echo $! > {pidFile}; wait\"", null, 1);
            watch.Stop();
            int child = int.Parse(File.ReadAllText(pidFile).Trim());
            Check("past the Windows deadline the run is killed and reads as timed out",
                  hung == (-1, string.Empty, true) && watch.Elapsed < TimeSpan.FromSeconds(4));
            Check("the kill takes the child the shell started", await GoneWithin(child, TimeSpan.FromSeconds(3)));
        }
        finally
        {
            File.Delete(pidFile);
        }
    }

    private static async Task LinuxSide()
    {
        const int windows = 5;
        var watch = Stopwatch.StartNew();
        var hung = await WslCommand.RunAsync("/bin/sh", $"-c \"{WslCommand.Bounded("sleep 30", windows)}\"", null, windows);
        watch.Stop();
        // 124, not -1: `timeout` ended it, before the Windows kill had to.
        Check("the Linux side ends a hung command before Windows does",
              hung == (124, string.Empty, true) && watch.Elapsed < TimeSpan.FromSeconds(windows));

        // A client that ignores SIGTERM: the SIGKILL two seconds later takes
        // it. A script file keeps the quoting readable.
        const int windows2 = 6;
        string script = Path.Combine(Path.GetTempPath(), "fp-wsl-deadline-" + Guid.NewGuid().ToString("N") + ".sh");
        try
        {
            File.WriteAllText(script, WslCommand.Bounded("sh -c 'trap \"\" TERM; sleep 30'", windows2) + "\n");
            watch.Restart();
            var stubborn = await WslCommand.RunAsync("/bin/sh", script, null, windows2);
            watch.Stop();
            Check("a command that ignores SIGTERM is killed with its group",
                  stubborn == (137, string.Empty, true) && watch.Elapsed < TimeSpan.FromSeconds(windows2));
        }
        finally
        {
            File.Delete(script);
        }
    }

    private static async Task<bool> HasGnuTimeout()
    {
        var probe = await WslCommand.RunAsync("/bin/sh", "-c \"timeout --version\"", null, 0);
        return probe.exitCode == 0 && probe.stdout.Contains("GNU coreutils");
    }

    // Gone, or a zombie waiting to be reaped: either way no longer running.
    private static async Task<bool> GoneWithin(int pid, TimeSpan limit)
    {
        var deadline = DateTime.UtcNow + limit;
        while (DateTime.UtcNow < deadline)
        {
            var ps = await WslCommand.RunAsync("/bin/ps", $"-o stat= -p {pid}", null, 0);
            string stat = ps.stdout.Trim();
            if (stat.Length == 0 || stat.StartsWith("Z")) return true;
            await Task.Delay(100);
        }
        return false;
    }

    private static void Check(string name, bool ok)
    {
        if (ok) { passed++; Console.WriteLine("ok   " + name); }
        else { failed++; Console.WriteLine("FAIL " + name); }
    }

    private static void Skip(string name, string why)
    {
        skipped++;
        Console.WriteLine($"skip {name} ({why})");
    }
}
