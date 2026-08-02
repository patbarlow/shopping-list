import SwiftUI
import Charts

/// Spend-per-shop trends built from scanned receipts: stacked bars per trip
/// day (colored by store), an average line, and category totals for the range.
struct SpendTrendsView: View {
    let householdId: String
    @Environment(AppServices.self) private var services

    @State private var trips: [ShoppingTrip] = []
    @State private var categorySpend: [CategorySpend] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var range: TrendRange = .threeMonths

    enum TrendRange: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .all: return nil
            }
        }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
            } else if trips.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "chart.bar",
                    description: Text("Scan receipts and your spend per shop will show up here.")
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    statCards

                    sectionHeader("Spend per shop")
                    tripsChart

                    if !filteredCategoryTotals.isEmpty {
                        sectionHeader("Where it goes")
                        categoryChart
                    }

                    if !groupedTrips.isEmpty {
                        sectionHeader("Trips")
                        tripLog
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Spend Trends")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let response = try await services.api.fetchTrips(householdId: householdId)
                trips = response.trips
                categorySpend = response.categorySpend
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    // MARK: - Derived data

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(_ s: String) -> Date? {
        Self.dayFormatter.date(from: String(s.prefix(10)))
    }

    private var cutoff: Date? {
        guard let days = range.days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: .now))
    }

    private var filteredTrips: [(trip: ShoppingTrip, day: Date)] {
        trips.compactMap { trip in
            guard let d = day(trip.date) else { return nil }
            if let cutoff, d < cutoff { return nil }
            return (trip, d)
        }
    }

    private var dayTotals: [(day: Date, total: Double)] {
        Dictionary(grouping: filteredTrips, by: \.day)
            .map { (day: $0.key, total: $0.value.reduce(0) { $0 + ($1.trip.totalAmount ?? 0) }) }
            .sorted { $0.day < $1.day }
    }

    private var averagePerShopDay: Double? {
        guard !dayTotals.isEmpty else { return nil }
        return dayTotals.reduce(0) { $0 + $1.total } / Double(dayTotals.count)
    }

    private var totalSpend: Double {
        dayTotals.reduce(0) { $0 + $1.total }
    }

    // Brand color assignment is computed over ALL trips (not the filtered
    // range) so a store keeps its color when the range changes.
    private static let knownBrandColors: [String: Color] = [
        "Woolworths": .green,
        "Aldi": .blue,
        "Coles": .red,
        "Iga": .orange,
    ]
    private static let fallbackColors: [Color] = [.purple, .teal, .brown, .pink]

    private var brandDomain: [String] {
        var seen: [String] = []
        for trip in trips where !seen.contains(trip.brand) {
            seen.append(trip.brand)
        }
        return seen
    }

    private var brandColors: [Color] {
        var fallback = Self.fallbackColors.makeIterator()
        return brandDomain.map { Self.knownBrandColors[$0] ?? (fallback.next() ?? .gray) }
    }

    private var filteredCategoryTotals: [(category: String, total: Double)] {
        let rows = categorySpend.filter { row in
            guard let d = day(row.date) else { return false }
            if let cutoff { return d >= cutoff }
            return true
        }
        let totals = Dictionary(grouping: rows, by: \.category)
            .map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.total }) }
            .sorted { $0.total > $1.total }
        guard totals.count > 8 else { return totals }
        let top = Array(totals.prefix(7))
        let rest = totals.dropFirst(7).reduce(0) { $0 + $1.total }
        return top + [(category: "Other", total: rest)]
    }

    private var groupedTrips: [(day: Date, trips: [ShoppingTrip])] {
        Dictionary(grouping: filteredTrips, by: \.day)
            .map { (day: $0.key, trips: $0.value.map(\.trip)) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Stat cards

    private var statCards: some View {
        HStack(spacing: 10) {
            statCard(title: "Total", value: currencyShort(totalSpend), caption: "in range")
            statCard(title: "Per shop", value: averagePerShopDay.map { currencyShort($0) } ?? "—", caption: "average")
            statCard(title: "Trips", value: "\(dayTotals.count)", caption: "shop days")
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

    // MARK: - Charts

    private var tripsChart: some View {
        Chart {
            ForEach(filteredTrips, id: \.trip.id) { entry in
                BarMark(
                    x: .value("Day", entry.day, unit: .day),
                    y: .value("Spend", entry.trip.totalAmount ?? 0),
                    width: .ratio(0.55)
                )
                .foregroundStyle(by: .value("Store", entry.trip.brand))
                .cornerRadius(4)
            }

            // Invisible point at each day's stack top carries the total label.
            if dayTotals.count <= 12 {
                ForEach(dayTotals, id: \.day) { entry in
                    PointMark(
                        x: .value("Day", entry.day, unit: .day),
                        y: .value("Spend", entry.total)
                    )
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 4) {
                        Text(currencyShort(entry.total))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let avg = averagePerShopDay, dayTotals.count >= 2 {
                RuleMark(y: .value("Average", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .annotation(position: .bottom, alignment: .trailing) {
                        Text("avg \(currencyShort(avg))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: brandDomain, range: brandColors)
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 240)
    }

    private var categoryChart: some View {
        Chart(filteredCategoryTotals, id: \.category) { row in
            BarMark(
                x: .value("Spend", row.total),
                y: .value("Category", row.category)
            )
            .foregroundStyle(.tint)
            .cornerRadius(4)
            .annotation(position: .trailing, spacing: 6) {
                Text(currencyShort(row.total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended) { _ in
                AxisValueLabel()
            }
        }
        .frame(height: CGFloat(filteredCategoryTotals.count) * 32 + 8)
    }

    // MARK: - Trip log

    private var tripLog: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groupedTrips, id: \.day) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.subheadline.weight(.semibold))
                    VStack(spacing: 0) {
                        ForEach(Array(group.trips.enumerated()), id: \.element.id) { i, trip in
                            if i > 0 { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trip.brand)
                                        .font(.subheadline)
                                    if trip.itemCount > 0 {
                                        Text("\(trip.itemCount) item\(trip.itemCount == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let total = trip.totalAmount {
                                    Text(total, format: .currency(code: "AUD"))
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Formatting

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }

    /// "$201" / "$77.10" — whole dollars unless cents matter, to keep bar labels tight.
    private func currencyShort(_ value: Double) -> String {
        if value.rounded() == value {
            return value.formatted(.currency(code: "AUD").precision(.fractionLength(0)))
        }
        return value.formatted(.currency(code: "AUD"))
    }
}
