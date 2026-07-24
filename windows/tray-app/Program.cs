// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

using System;
using System.Windows.Forms;
using System.Threading;

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

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            var app = new TrayApp();
            Application.Run();

            app.Dispose();
            _mutex.ReleaseMutex();
        }
    }
}
