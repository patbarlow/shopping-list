import SwiftUI

/// Browse every product you've bought on a receipt, with how often and how much.
/// Shown as its own page; tapping a product pushes its detail page.
struct ProductsListView: View {
    let householdId: String
    @Environment(AppServices.self) private var services

    @State private var products: [ProductInsight] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var search = ""
    @State private var displayed: [ProductInsight] = []
    @State private var sort: Sort = .frequency

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

    private func updateDisplayed() {
        let filtered = search.isEmpty ? products : products.filter { $0.name.localizedCaseInsensitiveContains(search) }
        displayed = filtered.sorted {
            switch sort {
            case .frequency:
                if $0.timesPurchased != $1.timesPurchased { return $0.timesPurchased > $1.timesPurchased }
            case .spend:
                if $0.totalSpend != $1.totalSpend { return ($0.totalSpend ?? 0) > ($1.totalSpend ?? 0) }
            case .recent:
                if $0.lastPurchasedAt != $1.lastPurchasedAt { return ($0.lastPurchasedAt ?? "") > ($1.lastPurchasedAt ?? "") }
            case .name: break
            }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
            } else if let err = errorMessage {
                ContentUnavailableView("Couldn't load products", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if products.isEmpty {
                ContentUnavailableView(
                    "No products yet",
                    systemImage: "cart",
                    description: Text("Scan a receipt and the things you buy will show up here with prices and how often you buy them.")
                )
            } else {
                List(displayed) { product in
                    NavigationLink {
                        ProductDetailView(householdId: householdId, productId: product.id, fallbackName: product.name)
                            .environment(services)
                    } label: { row(product) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .overlay {
                    if displayed.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Attached via .background rather than as a ZStack sibling in front
        // of the ScrollView — that arrangement kept the ScrollView from being
        // recognized as the NavigationStack's scrollable content, so the
        // large title's extra height never got automatically reserved for it
        // (needing a hand-tuned top-padding fudge that was never quite right,
        // and threw off the system's own scroll-to-top-on-tab-tap since it
        // targets the real, automatic inset). As a .background this stays a
        // passive layer behind the content without interfering with that.
        .background {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                Self.headerGradient
                    .frame(height: 700)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .searchable(text: $search, prompt: "Find a product")
        .onChange(of: search) { _, _ in updateDisplayed() }
        .onChange(of: sort) { _, _ in updateDisplayed() }
        .navigationTitle("Products")
        .navigationBarTitleDisplayMode(.large)
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
                updateDisplayed()
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
                    updateDisplayed()
                }
            }
        }
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
            parts.append("last \(d.formatted(.dateTime.day().month(.abbreviated)))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
