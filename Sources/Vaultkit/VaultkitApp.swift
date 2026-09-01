import SwiftUI

@main
struct VaultkitApp: App {
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
