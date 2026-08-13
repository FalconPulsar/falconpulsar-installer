// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.IO;
using System.Windows.Forms;
using System.Threading;
using System.Threading.Tasks;

namespace FalconPulsar.Tray
{
    static class Program
    {
        private static Mutex _mutex;

        [STAThread]
        static void Main(string[] args)
        {
            // Single-instance: prevent multiple copies from running
            const string mutexName = "FalconPulsarTray_SingleInstance";
            _mutex = new Mutex(true, mutexName, out bool isNew);
            if (!isNew)
            {
                return;
            }

            // QuickDock is a background tray app: nobody is watching it, and it is
            // expected to still be there tomorrow. Without these, ONE unhandled
            // exception ends the process and the icon simply vanishes — which is
            // what users saw after several hours, when WSL had idled its VM down
            // and the poll's WSL/UNC reads started throwing.
            //
            // Route UI-thread exceptions through ThreadException instead of letting
            // the runtime terminate, and catch what escapes other threads so the
            // reason is at least recorded.
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => LogUnexpected("ui-thread", e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
                LogUnexpected("background", e.ExceptionObject as Exception);
            // An async void handler whose Task faults after nobody awaited it lands
            // here rather than on a thread that would tear the process down.
            TaskScheduler.UnobservedTaskException += (s, e) =>
            {
                LogUnexpected("unobserved-task", e.Exception);
                e.SetObserved();
            };

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            var app = new TrayApp();
            Application.Run();

            app.Dispose();
            _mutex.ReleaseMutex();
        }

        /// <summary>
        /// Records a fault that would otherwise have been the last thing the tray
        /// ever did. Deliberately best-effort and silent: a message box on a
        /// background thread hours after login is worse than a log line, and a
        /// failure to log must not become the thing that kills the process.
        /// </summary>
        private static void LogUnexpected(string origin, Exception ex)
        {
            try
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "FalconPulsar");
                Directory.CreateDirectory(dir);
                File.AppendAllText(
                    Path.Combine(dir, "quickdock.log"),
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{origin}] {ex}{Environment.NewLine}");
            }
            catch
            {
                // Nothing sensible left to do.
            }
        }
    }
}
