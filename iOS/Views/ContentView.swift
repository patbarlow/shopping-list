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
                            InsightsHubView(household: household)
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
