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
        .windowStyle(.titleBar)
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
        Settings {
            Group {
                if let household = services.auth.household {
                    MacSettingsView(household: household)
                } else {
                    Text("Sign in to manage your household settings.").padding(40)
                }
            }.environment(services)
        }
    }
}
