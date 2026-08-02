import SwiftUI

/// The Insights tab: one hub page linking out to trends, products, forecast,
/// and purchase history, each pushed on this tab's own navigation stack.
struct InsightsHubView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SpendTrendsView(householdId: household.id)
                            .environment(services)
                    } label: {
                        Label("Spend Trends", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink {
                        ProductsListView(householdId: household.id)
                            .environment(services)
                    } label: {
                        Label("Products", systemImage: "basket")
                    }
                    NavigationLink {
                        PredictedListView(householdId: household.id, shoppingFrequency: household.shoppingFrequency)
                            .environment(services)
                    } label: {
                        Label("Forecast", systemImage: "calendar.badge.clock")
                    }
                    NavigationLink {
                        HistoryDaysListView(householdId: household.id)
                            .environment(services)
                    } label: {
                        Label("Purchase History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("Insights")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(household: household).environment(services)
            }
        }
    }
}

/// All shop days, pushed from the hub; each day pushes its item breakdown.
struct HistoryDaysListView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @State private var days: [HistoryDay] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if days.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Days you shop will show up here.")
                )
            } else {
                List(days) { day in
                    NavigationLink {
                        HistoryDayView(householdId: householdId, date: day.date, onBack: {})
                            .environment(services)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.dayOfWeek)
                                    .font(.subheadline.weight(.semibold))
                                Text(day.displayDate)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(day.itemCount)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color(.systemGray5), in: Circle())
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Purchase History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            days = (try? await services.api.fetchHistoryDays(householdId: householdId)) ?? []
            isLoading = false
        }
    }
}
