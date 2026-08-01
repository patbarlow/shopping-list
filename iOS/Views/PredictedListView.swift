import SwiftUI

/// Products likely due for a re-buy before your next big shop, based on each
/// product's typical shopping-trip cadence and your shopping frequency setting,
/// with an estimated cost. Items can be added straight onto the shopping list.
struct PredictedListView: View {
    let householdId: String
    let shoppingFrequency: ShoppingFrequency
    @Environment(AppServices.self) private var services

    @State private var response: PredictedListResponse? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    /// Names already on the shopping list (lowercased) — shown as ticked.
    @State private var onListNames: Set<String> = []

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                ContentUnavailableView("Couldn't load forecast", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if let response, response.items.isEmpty {
                ContentUnavailableView(
                    "Not enough data yet",
                    systemImage: "calendar.badge.clock",
                    description: Text("Scan a few more receipts and we'll start predicting what you'll need before your next big shop.")
                )
            } else if let response {
                List {
                    Section {
                        summaryCard(response)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    let (dueNow, upcoming) = splitItems(response.items)
                    if !dueNow.isEmpty {
                        Section("This shop") {
                            ForEach(dueNow) { row($0) }
                        }
                    }
                    if !upcoming.isEmpty {
                        Section("Probably next shop") {
                            ForEach(upcoming) { row($0) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
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
            Text("PREDICTED FOR YOUR NEXT SHOP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(currency(response.predictedTotal))
                .font(.largeTitle.weight(.bold))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 6)
    }

    // MARK: - Row

    private func row(_ item: PredictedItem) -> some View {
        let category = ItemCategory(rawValue: item.category) ?? .other
        return HStack(spacing: 12) {
            Text(category.emoji)
                .font(.title3)
                .frame(width: 30)

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
        .padding(.vertical, 2)
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
