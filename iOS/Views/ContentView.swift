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
        @Bindable var receiptImportCoordinator = receiptImportCoordinator
        return Group {
            #if DEBUG
            if let scenario = ProcessInfo.processInfo.environment["TROLLEY_UI_TEST"] {
                if scenario == "app" || scenario.hasPrefix("list-") {
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
        .sheet(item: $receiptImportCoordinator.mediaPicker,
               onDismiss: receiptImportCoordinator.presentQueuedCapture) { source in
            Group {
                switch source {
                case .camera, .scan: CompactCameraPicker(scan: source == .scan, onCapture: receiptImportCoordinator.finishMedia)
                case .photos: CompactPhotoPicker(onSelect: receiptImportCoordinator.finishMedia)
                }
            }
            .modifier(MediaZoomTransition(namespace: receiptImportCoordinator.transitionNamespace, sourceID: "receipt"))
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
        @Bindable var receiptImportCoordinator = receiptImportCoordinator
        return TabView(selection: $selectedTab) {
            Tab(value: AppTab.list) {
                ShoppingListView(household: household, voice: voice)
            } label: {
                Image(hugeIcon: "cart").accessibilityLabel("List")
            }
            Tab(value: AppTab.insights) {
                SpendTrendsView(household: household)
            } label: {
                Image(hugeIcon: "chart.bar").accessibilityLabel("Insights")
            }
            Tab(value: AppTab.price) {
                NavigationStack { PriceCheckView(householdId: household.id) }
            } label: {
                Image(hugeIcon: "tag").accessibilityLabel("Check price")
            }
            Tab(value: AppTab.forecast) {
                NavigationStack { PredictedListView(household: household) }
            } label: {
                Image(hugeIcon: "calendar.badge.clock").accessibilityLabel("Forecast")
            }
        }
        .sheet(item: $receiptImportCoordinator.pendingCapture) { capture in
            ReceiptScannerView(householdId: household.id, initialCapture: capture)
                .environment(services)
        }
        .tabBarMinimizeBehavior(.never)
        .onChange(of: selectedTab) { _, _ in AppHaptics.selection() }
        .overlay(alignment: .bottom) {
            VoiceScreenGlow(active: voice.isActive, level: voice.speech.level)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var authenticatedContent: some View {
        return Group {
            if services.auth.isLoggedIn {
                if let household = services.auth.household {
                    householdTabs(household)
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
