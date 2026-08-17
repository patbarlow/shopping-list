import SwiftUI

/// Products likely due for a re-buy before your next big shop, based on each
/// product's typical shopping-trip cadence and your shopping frequency setting,
/// with an estimated cost. Items can be added straight onto the shopping list.
struct PredictedListView: View {
    let household: Household
    @Environment(AppServices.self) private var services

    private var householdId: String { household.id }
    private var shoppingFrequency: ShoppingFrequency { household.shoppingFrequency }

    @State private var response: PredictedListResponse? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    /// Names already on the shopping list (lowercased) — shown as ticked.
    @State private var onListNames: Set<String> = []
    @State private var showSettings = false

    /// A coral/salmon wash — same treatment as Spend Trends' mint, in the warm
    /// tone that distinguishes "what's coming up" from "what happened."
    private static let headerGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.97, green: 0.62, blue: 0.53), location: 0),
            .init(color: Color(red: 0.97, green: 0.68, blue: 0.60).opacity(0.85), location: 0.2),
            .init(color: Color(red: 0.97, green: 0.74, blue: 0.68).opacity(0.5), location: 0.45),
            .init(color: Color(red: 0.97, green: 0.80, blue: 0.76).opacity(0.18), location: 0.7),
            .init(color: Color(red: 0.97, green: 0.80, blue: 0.76).opacity(0), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            Self.headerGradient
                .frame(height: 700)
                .ignoresSafeArea(edges: .top)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
            } else if let err = errorMessage {
                ContentUnavailableView("Couldn't load forecast", systemImage: "exclamationmark.triangle", description: Text(err))
                    .padding(.top, 60)
            } else if let response, response.items.isEmpty {
                ContentUnavailableView(
                    "Not enough data yet",
                    systemImage: "calendar.badge.clock",
                    description: Text("Scan a few more receipts and we'll start predicting what you'll need before your next big shop.")
                )
                .padding(.top, 60)
            } else if let response {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summaryCard(response)

                        let (dueNow, upcoming) = splitItems(response.items)
                        if !dueNow.isEmpty {
                            sectionHeader("This shop")
                            card { rows(dueNow) }
                        }
                        if !upcoming.isEmpty {
                            sectionHeader("Probably next shop")
                            card { rows(upcoming) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Forecast")
        // A large title collapsing into the inline one as you scroll is
        // ordinary NavigationStack behavior — the system handles the
        // fade/blur of content passing behind the bar as part of that,
        // reliably, the same way in a TestFlight build as it does when
        // Xcode installs the app straight onto a device. That's exactly the
        // transition the manual fade overlay and scrollEdgeEffectStyle were
        // both trying (and, in TestFlight's case, failing) to fake by hand —
        // and it also means the content no longer needs a manual top-padding
        // fudge to clear the bar, since the large title already reserves
        // that space itself.
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 22, height: 22)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                ReceiptImportToolbarButton(householdId: householdId)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(household: household).environment(services)
        }
        .task {
            do {
                async let predicted = services.api.fetchPredictedList(householdId: householdId)
                async let listItems = services.api.fetchItems(householdId: householdId)
                response = try await predicted
                onListNames = Set(try await listItems.filter { !$0.checked }.map { $0.name.lowercased() })
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    // MARK: - Sections

    /// Items whose predicted date has arrived belong to this shop; the rest of
    /// the horizon is next shop's problem.
    private func splitItems(_ items: [PredictedItem]) -> ([PredictedItem], [PredictedItem]) {
        let todayKey = Self.dayFormatter.string(from: Date())
        let dueNow = items.filter { $0.predictedDate <= todayKey }
        let upcoming = items.filter { $0.predictedDate > todayKey }
        return (dueNow, upcoming)
    }

    // MARK: - Summary

    private func summaryCard(_ response: PredictedListResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currencyRounded(response.predictedTotal))
                .font(.title.weight(.heavy))
            Text("^[\(response.items.count) item](inflect: true) likely due through \(displayDate(response.range.end))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let pending = response.items.filter { !isOnList($0) }
            if !pending.isEmpty {
                Button {
                    addAll(pending)
                } label: {
                    Label("Add ^[\(pending.count) item](inflect: true) to list", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
    }

    // MARK: - Card container

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: - Rows

    private func rows(_ items: [PredictedItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().padding(.leading, 16) }
                row(item)
            }
        }
    }

    private func row(_ item: PredictedItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text("\(cadenceLabel(item.avgIntervalDays)) · last \(displayShortDate(item.lastPurchasedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let price = item.predictedPrice {
                Text(currency(price))
                    .font(.subheadline.weight(.semibold))
            }

            if isOnList(item) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                Button {
                    addAll([item])
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Add to list

    private func isOnList(_ item: PredictedItem) -> Bool {
        onListNames.contains(item.name.lowercased())
    }

    private func addAll(_ items: [PredictedItem]) {
        // Optimistic: tick immediately, revert any that fail.
        for item in items { onListNames.insert(item.name.lowercased()) }
        Task {
            for item in items {
                do {
                    _ = try await services.api.createItem(householdId: householdId, name: item.name)
                } catch {
                    onListNames.remove(item.name.lowercased())
                }
            }
        }
    }

    // MARK: - Cadence

    /// "every 11 days" means nothing to a household that shops on Saturdays —
    /// express the interval in trips: "Every shop", "Every 2nd shop", …
    private func cadenceLabel(_ intervalDays: Int) -> String {
        let shops = max(1, Int((Double(intervalDays) / Double(shoppingFrequency.tripDays)).rounded()))
        if shops == 1 { return "Every shop" }
        let ordinal = Self.ordinalFormatter.string(from: NSNumber(value: shops)) ?? "\(shops)th"
        return "Every \(ordinal) shop"
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD"))
    }

    /// The headline predicted-total is an insight number, not a receipt line —
    /// rounded to the nearest dollar like Spend Trends. Per-item prices below
    /// it keep cents since they're closer to a product-level detail.
    private func currencyRounded(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD").precision(.fractionLength(0)))
    }

    private func displayDate(_ day: String) -> String {
        guard let d = Self.dayFormatter.date(from: day) else { return day }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private func displayShortDate(_ day: String) -> String {
        guard let d = Self.dayFormatter.date(from: String(day.prefix(10))) else { return day }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d)
    }
}
