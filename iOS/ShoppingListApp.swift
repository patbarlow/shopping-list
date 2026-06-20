import SwiftUI
import Sentry
import UniformTypeIdentifiers


@main
struct ShoppingListApp: App {
    init() {
        ShoppingCore.migrateIfNeeded()
SentrySDK.start { options in
            options.dsn = "https://4fbbe6fdbd49ab9139757d8b8a1de53f@o4511482336772096.ingest.us.sentry.io/4511482454933504"

            // Adds IP for users.
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = true

            // Set tracesSampleRate to 1.0 to capture 100% of transactions for performance monitoring.
            // We recommend adjusting this value in production.
            options.tracesSampleRate = 1.0

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0 // We recommend adjusting this value in production.
                $0.lifecycle = .trace
            }

            // Uncomment the following lines to add more data to your events
            // options.attachScreenshot = true // This adds a screenshot to the error events
            // options.attachViewHierarchy = true // This adds the view hierarchy to the error events
            
            // Enable experimental logging features
            options.experimental.enableLogs = true
        }
    }
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
                    services.realtime.connect(householdId: household.id)
                    Task { await services.shopping.fetch() }
                }
                .onOpenURL { url in
                    // Handle PDFs shared from other apps (e.g. Woolworths Rewards)
                    guard url.isFileURL,
                          url.pathExtension.lowercased() == "pdf" else { return }
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        services.pendingReceiptPDF = data
                    }
                }
        }
    }
}
