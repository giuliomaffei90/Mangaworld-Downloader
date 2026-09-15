import AppKit
import SwiftUI

@main
struct MangaworldApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var downloads = Downloads()

    init() {
        UserDefaults.standard.register(defaults: ["maxDownloads": 2])
    }

    var body: some Scene {
        Window("Mangaworld Downloader", id: "main") {
            ContentView().environment(downloads)
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        Settings { SettingsView().frame(width: 480, height: 260) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable, which macOS treats as a background tool until told otherwise.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
