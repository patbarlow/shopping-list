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

    /// A soft periwinkle wash — same treatment as Insights' mint and Forecast's
    /// coral, in a cooler tone for "what you buy" as distinct from spend or timing.
    private static let headerGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.72, green: 0.78, blue: 0.96), location: 0),
            .init(color: Color(red: 0.76, green: 0.81, blue: 0.96).opacity(0.85), location: 0.2),
            .init(color: Color(red: 0.80, green: 0.85, blue: 0.97).opacity(0.5), location: 0.45),
            .init(color: Color(red: 0.84, green: 0.88, blue: 0.98).opacity(0.18), location: 0.7),
            .init(color: Color(red: 0.84, green: 0.88, blue: 0.98).opacity(0), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

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
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            Self.headerGradient
                .frame(height: 700)
                .ignoresSafeArea(edges: .top)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
            } else if let err = errorMessage {
                ContentUnavailableView("Couldn't load products", systemImage: "exclamationmark.triangle", description: Text(err))
                    .padding(.top, 60)
            } else if products.isEmpty {
                ContentUnavailableView(
                    "No products yet",
                    systemImage: "cart",
                    description: Text("Scan a receipt and the things you buy will show up here with prices and how often you buy them.")
                )
                .padding(.top, 60)
            } else {
                ScrollView {
                    card {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, product in
                                if i > 0 { Divider().padding(.leading, 16) }
                                NavigationLink {
                                    ProductDetailView(householdId: householdId, productId: product.id, fallbackName: product.name)
                                        .environment(services)
                                } label: {
                                    row(product)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 32)
                    .padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
                // .automatic only reveals the field on a pull-down gesture, which
                // this page's custom ZStack header/scroll-edge styling was
                // swallowing before it could fully open. Always-visible sidesteps
                // that gesture entirely.
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            }
        }
        .navigationTitle("Products")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Kept in the toolbar unconditionally (just disabled while there's
            // nothing to sort) rather than only inserting it once `products`
            // loads — otherwise there's no button here yet when the push
            // transition starts, so the Insights buttons have nothing to morph
            // into and just vanish instead of animating across.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(products.isEmpty)
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

    // MARK: - Card container

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: - Row

    private func row(_ product: ProductInsight) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle(product))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let unitValue = product.avgUnitPrice, let unit = product.avgUnitPriceUnit {
                    HStack(spacing: 3) {
                        trendArrow(product)
                        unitPriceText(unitValue, unit)
                    }
                    Text("avg").font(.caption2).foregroundStyle(.tertiary)
                } else if let avg = product.avgPrice {
                    HStack(spacing: 3) {
                        trendArrow(product)
                        Text(avg, format: .currency(code: "AUD"))
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("avg").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The price is the number worth seeing at a glance — the unit label rides
    /// along smaller and quieter, e.g. "$0.24" in front of a faint " / 100g".
    private func unitPriceText(_ value: Double, _ unit: String) -> Text {
        Text(value, format: .currency(code: "AUD")).font(.subheadline.weight(.semibold))
            + Text(" / \(unit)").font(.caption2).foregroundStyle(.secondary)
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
