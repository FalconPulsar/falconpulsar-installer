// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import SwiftUI
import AppKit

@main
struct FalconPulsarInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppActivator.self) var appActivator

    var body: some Scene {
        WindowGroup {
            InstallerView()
                .frame(width: 620, height: 620)
        }
        .windowResizability(.contentSize)
    }
}

class AppActivator: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill any in-flight install.sh so it doesn't orphan-leak.
        InstallRunner.killActiveProcess()

        let bundlePath = Bundle.main.bundlePath
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "'\(lsregister)' -u '\(bundlePath)' 2>/dev/null"]
        try? task.run()
        task.waitUntilExit()

        // If we're running from a mounted DMG, schedule detached ejection
        // after the installer exits. Can't eject from our own process because
        // our executable is on the DMG.
        if bundlePath.hasPrefix("/Volumes/") {
            let components = bundlePath.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            if components.count >= 2 {
                let volumePath = "/Volumes/\(components[1])"
                let eject = Process()
                eject.launchPath = "/bin/bash"
                eject.arguments = ["-c", "nohup sh -c 'sleep 2; /usr/bin/hdiutil detach \"\(volumePath)\" -force >/dev/null 2>&1' >/dev/null 2>&1 &"]
                try? eject.run()
            }
        }
    }
}
