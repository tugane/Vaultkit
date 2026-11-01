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

    /// Quit is the one auto-secure trigger the store cannot own: AppKit asks
    /// here whether it may terminate, and while a vault is still open the
    /// answer has to be "wait".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = AutoSecureTermination.store,
              store.autoSecure.allows(.quit),
              store.hasVaultsToSecureOnQuit else { return .terminateNow }
        AutoSecureTermination.beginSweep(store)
        return .terminateLater
    }
}

/// Holds termination open for one auto-secure sweep, and hands the store to a
/// delegate SwiftUI builds for us and never introduces to it.
@MainActor
enum AutoSecureTermination {
    weak static var store: AppStore?

    /// A hard ceiling on how long quitting may hang. One eject can sleep five
    /// seconds and then shell out to diskutil with no timeout of its own, and
    /// an app that will not quit is worse than a vault that closes a minute
    /// later: the idle check will catch it on the next launch either way.
    static let budget: TimeInterval = 8

    private static var replied = false

    static func beginSweep(_ store: AppStore) {
        replied = false
        Task { @MainActor in
            await store.autoSecureSweep(trigger: .quit)
            allowTermination()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budget))
            allowTermination()
        }
    }

    private static func allowTermination() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
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
