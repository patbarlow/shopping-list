import SwiftUI

/// A single product's stats (times bought, average, all-time spend) and a
/// date-grouped log of every actual product bought under it, with prices.
struct ProductDetailView: View {
    let householdId: String
    let productId: String
    let fallbackName: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var detail: ProductInsightDetail? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                } else if let detail {
                    VStack(alignment: .leading, spacing: 20) {
                        statCards(detail.stats)
                        if let interval = detail.stats.avgIntervalDays, interval > 0 {
                            Label("You buy this about every \(interval) day\(interval == 1 ? "" : "s").", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        purchaseLog(detail.purchases)
                    }
                    .padding(16)
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .padding(.top, 80)
                }
            }
            .navigationTitle(detail?.product.name ?? fallbackName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                detail = try await services.api.fetchProductInsight(householdId: householdId, productId: productId)
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    // MARK: - Stat cards

    private func statCards(_ stats: ProductStats) -> some View {
        HStack(spacing: 10) {
            statCard(title: "Bought", value: "\(stats.timesPurchased)", caption: "times")
            statCard(title: "Average", value: stats.avgPrice.map { currency($0) } ?? "—", caption: "per buy")
            statCard(title: "All-time", value: stats.totalSpend.map { currency($0) } ?? "—", caption: "spent")
        }
    }

    private func statCard(title: String, value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Purchase log

    private var groupedPurchases: [(day: String, items: [ProductPurchase])] {
        guard let purchases = detail?.purchases else { return [] }
        let groups = Dictionary(grouping: purchases, by: \.dayKey)
        return groups.keys.sorted(by: >).map { (day: $0, items: groups[$0] ?? []) }
    }

    @ViewBuilder
    private func purchaseLog(_ purchases: [ProductPurchase]) -> some View {
        if purchases.isEmpty {
            Text("No receipt purchases recorded yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("PURCHASES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(groupedPurchases, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayDate(group.day))
                            .font(.subheadline.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, purchase in
                                if i > 0 { Divider() }
                                purchaseRow(purchase)
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func purchaseRow(_ purchase: ProductPurchase) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(purchase.variant?.isEmpty == false ? purchase.variant! : (detail?.product.name ?? fallbackName))
                    .font(.subheadline)
                if let store = purchase.storeName, !store.isEmpty {
                    Text(store).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let price = purchase.pricePaid {
                Text(currency(price)).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Formatting

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD"))
    }

    private func displayDate(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: d)
    }
}
