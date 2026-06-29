import SwiftUI

/// Browse every product you've bought on a receipt, with how often and how much.
struct ProductsListView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var products: [ProductInsight] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var sort: Sort = .frequency

    enum Sort: String, CaseIterable, Identifiable {
        case frequency = "Most bought"
        case spend     = "Top spend"
        case recent    = "Recent"
        case name      = "A–Z"
        var id: String { rawValue }
    }

    private var sorted: [ProductInsight] {
        switch sort {
        case .frequency: return products.sorted { $0.timesPurchased > $1.timesPurchased }
        case .spend:     return products.sorted { ($0.totalSpend ?? 0) > ($1.totalSpend ?? 0) }
        case .recent:    return products.sorted { ($0.lastPurchasedAt ?? "") > ($1.lastPurchasedAt ?? "") }
        case .name:      return products.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    ContentUnavailableView("Couldn't load products", systemImage: "exclamationmark.triangle", description: Text(err))
                } else if products.isEmpty {
                    ContentUnavailableView(
                        "No products yet",
                        systemImage: "cart",
                        description: Text("Scan a receipt and the things you buy will show up here with prices and how often you buy them.")
                    )
                } else {
                    List {
                        ForEach(sorted) { product in
                            NavigationLink {
                                ProductDetailView(householdId: householdId, productId: product.id, fallbackName: product.name)
                                    .environment(services)
                            } label: {
                                row(product)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !products.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                }
            }
        }
        .task {
            do {
                products = try await services.api.fetchProductInsights(householdId: householdId)
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    private func row(_ product: ProductInsight) -> some View {
        let category = ItemCategory(rawValue: product.category) ?? .other
        return HStack(spacing: 12) {
            Text(category.emoji)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.name).font(.body.weight(.medium))
                Text("Bought ^[\(product.timesPurchased) time](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let avg = product.avgPrice {
                    Text(avg, format: .currency(code: "AUD"))
                        .font(.subheadline.weight(.semibold))
                    Text("avg").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
