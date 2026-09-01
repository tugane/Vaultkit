import SwiftUI

/// Running as a bare SPM executable (no .app bundle) the process defaults to a
/// background-style activation policy: windows render but never become key, so
/// keyboard input (e.g. the passphrase field) goes nowhere. Force regular.
final class ActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct VaultkitApp: App {
    @NSApplicationDelegateAdaptor(ActivationDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }

        // Menu-bar quick access: vault mount/eject without opening the main window.
        MenuBarExtra("Vaultkit", systemImage: "lock.shield") {
            MenuBarView()
                .environmentObject(store)
        }
    }
}
