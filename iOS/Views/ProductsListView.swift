import SwiftUI

/// Browse every product you've bought on a receipt, with how often and how much.
/// Shown as its own page; tapping a product pushes its detail page.
struct ProductsListView: View {
    let householdId: String
    @Environment(AppServices.self) private var services

    @State private var products: [ProductInsight] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var sort: Sort = .frequency
    @State private var searchText = ""

    enum Sort: String, CaseIterable, Identifiable {
        case frequency = "Most bought"
        case spend     = "Top spend"
        case recent    = "Recent"
        case name      = "A–Z"
        var id: String { rawValue }
    }

    private var sorted: [ProductInsight] {
        let filtered = searchText.isEmpty
            ? products
            : products.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sort {
        case .frequency: return filtered.sorted { $0.timesPurchased > $1.timesPurchased }
        case .spend:     return filtered.sorted { ($0.totalSpend ?? 0) > ($1.totalSpend ?? 0) }
        case .recent:    return filtered.sorted { ($0.lastPurchasedAt ?? "") > ($1.lastPurchasedAt ?? "") }
        case .name:      return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
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
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
            }
        }
        .navigationTitle("Products")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .task {
            do {
                products = try await services.api.fetchProductInsights(householdId: householdId)
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
        .onAppear {
            // Fires again when popping back from a detail page — pick up renames/merges.
            guard !isLoading else { return }
            Task {
                if let fresh = try? await services.api.fetchProductInsights(householdId: householdId) {
                    products = fresh
                }
            }
        }
    }

    private func row(_ product: ProductInsight) -> some View {
        let category = ItemCategory(rawValue: product.category) ?? .other
        return HStack(spacing: 12) {
            Text(category.emoji)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle(product))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let avg = product.avgPrice {
                    HStack(spacing: 3) {
                        trendArrow(product)
                        Text(avg, format: .currency(code: "AUD"))
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("avg").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Last price above/below the running average by 5%+ — the shelf-tag fact
    /// supermarkets never print.
    @ViewBuilder
    private func trendArrow(_ product: ProductInsight) -> some View {
        switch product.priceTrend {
        case .up:   Image(systemName: "arrow.up").font(.caption2.bold()).foregroundStyle(.red)
        case .down: Image(systemName: "arrow.down").font(.caption2.bold()).foregroundStyle(.green)
        case nil:   EmptyView()
        }
    }

    private func subtitle(_ product: ProductInsight) -> String {
        var parts = ["\(product.timesPurchased)×"]
        if let last = product.lastPurchasedAt, let d = Self.dayFormatter.date(from: String(last.prefix(10))) {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("d MMM")
            parts.append("last \(f.string(from: d))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
