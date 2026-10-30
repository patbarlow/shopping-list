import SwiftUI
import Sentry
import Sparkle

@main
struct ShoppingListMacApp: App {
    @State private var services = AppServices()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: !Self.isDevelopmentBuild, updaterDelegate: nil, userDriverDelegate: nil)

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    init() {
        ShoppingCore.migrateIfNeeded()
        // One-time adoption of the requested Mac default; subsequent choices persist.
        if !UserDefaults.standard.bool(forKey: "trolley_floating_default_v205") {
            UserDefaults.standard.set(true, forKey: "mac_always_on_top")
            UserDefaults.standard.set(true, forKey: "trolley_floating_default_v205")
        }
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
        Window("Trolley", id: "main") {
            MacRootView()
                .environment(services)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            MacCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
