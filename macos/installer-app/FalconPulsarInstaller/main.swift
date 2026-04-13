import SwiftUI
import AppKit

@main
struct FalconPulsarInstallerApp: App {
    @NSApplicationDelegateAdaptor(AppActivator.self) var appActivator

    var body: some Scene {
        WindowGroup {
            InstallerView()
                .frame(width: 600, height: 500)
        }
        .windowResizability(.contentSize)
    }
}

class AppActivator: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
