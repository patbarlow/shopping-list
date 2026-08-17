import SwiftUI

struct ContentView: View {
    @Environment(AppServices.self) private var services
    @Environment(ReceiptImportCoordinator.self) private var receiptImportCoordinator

    var body: some View {
        // A local @Bindable shadow of the environment object — the standard
        // way to get a two-way Binding (for .sheet(item:)) out of something
        // injected via .environment(...) rather than owned as local @State.
        @Bindable var receiptImportCoordinator = receiptImportCoordinator
        Group {
            if services.auth.isLoggedIn {
                if let household = services.auth.household {
                    TabView {
                        Tab("List", systemImage: "cart") {
                            ShoppingListView(household: household)
                        }
                        Tab("Insights", systemImage: "chart.bar") {
                            SpendTrendsView(household: household)
                        }
                        Tab("Forecast", systemImage: "calendar.badge.clock") {
                            NavigationStack {
                                PredictedListView(household: household)
                                    .environment(services)
                            }
                        }
                    }
                    // Anchored here — the TabView's root, always "in window"
                    // regardless of which tab is frontmost — rather than on
                    // ShoppingListView specifically. A share-sheet import
                    // (or the toolbar menu) landing while a different tab is
                    // active used to try presenting from a view controller
                    // that wasn't currently on screen, so the sheet just
                    // silently queued until the user happened to switch back
                    // to the List tab.
                    .sheet(item: $receiptImportCoordinator.pendingCapture) { capture in
                        ReceiptScannerView(householdId: household.id, initialCapture: capture)
                            .environment(services)
                    }
                    .onChange(of: services.pendingReceiptPDF) { _, pdf in
                        guard let pdf else { return }
                        services.pendingReceiptPDF = nil
                        receiptImportCoordinator.pendingCapture = .pdfData(pdf)
                    }
                } else {
                    HouseholdSetupView()
                }
            } else {
                LoginView()
            }
        }
        .task {
            if services.auth.isLoggedIn && services.auth.household == nil {
                await services.auth.loadHousehold()
            }
        }
    }
}
