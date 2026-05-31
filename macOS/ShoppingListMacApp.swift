import SwiftUI

@main
struct ShoppingListMacApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(services)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 580)
    }
}
