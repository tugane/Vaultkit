import SwiftUI
import TuganeDesign

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
    @AppStorage("vk.theme") private var themeRaw = Theme.dark.rawValue

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .dark }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.palette, theme.palette)
                .preferredColorScheme(theme.colorScheme)
                .overlay { NoiseOverlay() }   // the language's film grain
                .frame(minWidth: 940, minHeight: 640)
        }
        // Auger's chrome: no system title bar, so sidebar and content (glow,
        // grain, backgrounds) run edge to edge under the traffic lights.
        .windowStyle(.hiddenTitleBar)

        // Menu-bar quick access: vault mount/eject without opening the main window.
        MenuBarExtra("Vaultkit", systemImage: "lock.shield") {
            MenuBarView()
                .environmentObject(store)
                .environment(\.palette, theme.palette)
        }
    }
}
