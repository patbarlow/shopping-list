import SwiftUI

struct ContentView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
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
                                PredictedListView(householdId: household.id, shoppingFrequency: household.shoppingFrequency)
                                    .environment(services)
                            }
                        }
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
