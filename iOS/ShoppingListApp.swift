import SwiftUI

@main
struct ShoppingListApp: App {
    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .task {
                    // Register Siri / Action button shortcuts
                    ShoppingListShortcuts.updateAppShortcutParameters()
                }
                // onChange(of:) with (old, new) args is a View modifier (iOS 17+),
                // not a Scene modifier — attach it here, not on the WindowGroup.
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active,
                          services.auth.isLoggedIn,
                          let household = services.auth.household else { return }
                    // Reconnect the SSE stream (iOS may have killed it while backgrounded)
                    // and do an immediate fetch so the list is current before the stream
                    // delivers its first event.
                    services.realtime.connect(householdId: household.id)
                    Task { await services.shopping.fetch() }
                }
        }
    }
}
