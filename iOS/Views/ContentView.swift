import SwiftUI

struct ContentView: View {
    private enum AppTab { case list, insights, price, forecast }
    @State private var selectedTab = AppTab.list
    @State private var voice = VoiceEntryController()
    @Environment(AppServices.self) private var services
    @Environment(ReceiptImportCoordinator.self) private var receiptImportCoordinator

    var body: some View {
        // A local @Bindable shadow of the environment object — the standard
        // way to get a two-way Binding (for .sheet(item:)) out of something
        // injected via .environment(...) rather than owned as local @State.
        Group {
            #if DEBUG
            if let scenario = ProcessInfo.processInfo.environment["TROLLEY_UI_TEST"] {
                if scenario == "app" {
                    householdTabs(Household(id: "fixture", name: "Our place", inviteCode: "TEST", shoppingFrequency: .weekly))
                } else {
                    NavigationStack {
                        if scenario == "receipt" {
                            ReceiptScannerView(householdId: "fixture", initialCapture: .pdfData(Self.receiptFixture))
                        } else if scenario == "products" {
                            ProductsListView(householdId: "fixture")
                        } else {
                            PriceCheckView(householdId: "fixture")
                        }
                    }
                }
            } else { authenticatedContent }
            #else
            authenticatedContent
            #endif
        }
    }

    #if DEBUG
    private static var receiptFixture: Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { context in
            context.beginPage()
            ("Woolworths Marrickville Metro\nRed Bull Energy Drink 4x250ml $7.80\nTOTAL $7.80" as NSString)
                .draw(in: CGRect(x: 20, y: 20, width: 260, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
    }
    #endif

    private func householdTabs(_ household: Household) -> some View {
        TabView(selection: $selectedTab) {
            Tab("List", systemImage: "cart", value: AppTab.list) {
                ShoppingListView(household: household, voice: voice) { selectedTab = .price }
            }
            Tab("Insights", systemImage: "chart.bar", value: AppTab.insights) {
                SpendTrendsView(household: household)
            }
            Tab("Check price", systemImage: "tag", value: AppTab.price) {
                NavigationStack { PriceCheckView(householdId: household.id) }
            }
            Tab("Forecast", systemImage: "calendar.badge.clock", value: AppTab.forecast) {
                NavigationStack { PredictedListView(household: household) }
            }
        }
        .tabBarMinimizeBehavior(.never)
        .overlay(alignment: .bottom) {
            VoiceScreenGlow(active: voice.isActive, level: voice.speech.level)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var authenticatedContent: some View {
        @Bindable var receiptImportCoordinator = receiptImportCoordinator
        return Group {
            if services.auth.isLoggedIn {
                if let household = services.auth.household {
                    householdTabs(household)
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
