import SwiftUI

/// A single product's stats (times bought, average, all-time spend) and a
/// date-grouped log of every actual product bought under it, with prices.
/// Pushed from the Products list.
struct ProductDetailView: View {
    let householdId: String
    let productId: String
    let fallbackName: String
    @Environment(AppServices.self) private var services

    @State private var detail: ProductInsightDetail? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    // Rename — a merge can move history to another product, so track the live id.
    @State private var activeProductId: String? = nil
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    renameText = detail?.product.name ?? fallbackName
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(detail == nil)
            }
        }
        .alert("Rename Product", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If another product already has this name, their purchase history will be combined.")
        }
        .task {
            await load(productId)
        }
    }

    private func load(_ id: String) async {
        do {
            detail = try await services.api.fetchProductInsight(householdId: householdId, productId: id)
            activeProductId = id
            errorMessage = nil
        } catch {
            errorMessage = "Please try again."
        }
        isLoading = false
    }

    private func rename() async {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let currentId = activeProductId ?? detail?.product.id else { return }
        do {
            let response = try await services.api.renameProduct(householdId: householdId, productId: currentId, name: name)
            await load(response.product.id)
        } catch {
            errorMessage = "Rename failed. Please try again."
        }
    }

    // MARK: - Stat cards

    private func statCards(_ stats: ProductStats) -> some View {
        HStack(spacing: 10) {
            statCard(value: "\(stats.timesPurchased)", label: "times bought")
            statCard(value: stats.avgPrice.map { currency($0) } ?? "—", label: "average per buy")
            statCard(value: stats.totalSpend.map { currency($0) } ?? "—", label: "all-time spend")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.heavy))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
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
                Text("Purchases")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
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
            VStack(alignment: .trailing, spacing: 2) {
                if let price = purchase.pricePaid {
                    Text(currency(price)).font(.subheadline.weight(.semibold))
                }
                if let unitPrice = purchase.unitPrice, let unit = purchase.unitPriceUnit {
                    unitPriceText(unitPrice, unit)
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Formatting

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD"))
    }

    /// The price is the number worth seeing at a glance — the unit label rides
    /// along smaller and quieter after it.
    private func unitPriceText(_ value: Double, _ unit: String) -> Text {
        Text(currency(value)).font(.caption).foregroundStyle(.secondary)
            + Text(" / \(unit)").font(.caption2).foregroundStyle(.tertiary)
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
