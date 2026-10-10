import AppKit
import SwiftUI

@main
struct BinWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var store = AppStore.shared

    var body: some Scene {
        // SwiftUI writes to `isInserted` on every update; only pass real changes through,
        // otherwise each write re-renders the app and triggers another write (an endless loop).
        MenuBarExtra(isInserted: Binding(
            get: { store.settings.showMenuBarIcon },
            set: { if store.settings.showMenuBarIcon != $0 { store.settings.showMenuBarIcon = $0 } })
        ) {
            MenuBarView().environmentObject(store)
        } label: {
            Image(systemName: store.pendingAlerts.isEmpty ? "lock.rectangle.stack" : "lock.open.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Behaves like Spotify: a normal Dock app whose window you can close while it keeps working.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = AppStore.shared
        _ = RequestCenter.shared
        ManageWindow.show()
        if CommandLine.arguments.contains("--test-alert") {
            AppStore.shared.showTestAlert(count: 3)
        }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ManageWindow.show()
        return true
    }

    /// Closing the window doesn't quit — monitoring carries on. Quit with ⌘Q or from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
