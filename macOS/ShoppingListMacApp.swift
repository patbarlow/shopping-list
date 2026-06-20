import SwiftUI
import Sentry
import Sparkle
import ShoppingCore

@main
struct ShoppingListMacApp: App {
    @State private var services = AppServices()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        ShoppingCore.migrateIfNeeded()
        SentrySDK.start { options in
            options.dsn = "https://4fbbe6fdbd49ab9139757d8b8a1de53f@o4511482336772096.ingest.us.sentry.io/4511482454933504"
            options.sendDefaultPii = true
            options.tracesSampleRate = 1.0
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0
                $0.lifecycle = .trace
            }
            options.experimental.enableLogs = true
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(services)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 580)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
