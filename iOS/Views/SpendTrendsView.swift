import SwiftUI
import Charts

/// The Insights tab's root page: spend trends built from scanned receipts —
/// stacked bars per trip day (colored by store), category totals, and a trip
/// log (grouped by day, drilling into a receipt-style view per shop).
struct SpendTrendsView: View {
    let household: Household
    @Environment(AppServices.self) private var services
    @State private var showSettings = false

    private var householdId: String { household.id }

    @State private var trips: [ShoppingTrip] = []
    @State private var categorySpend: [CategorySpend] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var range: TrendRange = .threeMonths
    @State private var selectedDayKey: String? = nil

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

    /// A soft, pale mint wash that lingers well past the header — like Health's
    /// per-category pages — rather than a saturated banner with a hard edge.
    private static let headerGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.78, green: 0.93, blue: 0.82), location: 0),
            .init(color: Color(red: 0.80, green: 0.94, blue: 0.84).opacity(0.85), location: 0.2),
            .init(color: Color(red: 0.83, green: 0.95, blue: 0.86).opacity(0.5), location: 0.45),
            .init(color: Color(red: 0.85, green: 0.96, blue: 0.88).opacity(0.18), location: 0.7),
            .init(color: Color(red: 0.85, green: 0.96, blue: 0.88).opacity(0), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                Self.headerGradient
                    .frame(height: 700)
                    .ignoresSafeArea(edges: .top)

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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            rangePicker

                            statCards

                            if let insightText {
                                insightCard(insightText)
                            }

                            sectionHeader("Spend per shop")
                            card { tripsChart }

                            if !filteredCategoryTotals.isEmpty {
                                sectionHeader("Where it goes")
                                card { categoryChart }
                            }

                            if !groupedTrips.isEmpty {
                                sectionHeader("Trips")
                                tripLog
                            }
                        }
                        .padding(16)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        ProductsListView(householdId: householdId).environment(services)
                    } label: {
                        Image(systemName: "basket")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(household: household).environment(services)
            }
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

    /// Stable ordinal key for a day, used as the chart's x-axis category so
    /// bars sit shoulder-to-shoulder with no gap for days without a shop.
    private func dayKey(_ d: Date) -> String {
        Self.dayFormatter.string(from: d)
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

    /// Total for the equal-length period immediately preceding the current range,
    /// used to power the "X% more/less than last period" callout.
    private var previousPeriodTotal: Double? {
        guard let days = range.days, let cutoff else { return nil }
        guard let previousCutoff = Calendar.current.date(byAdding: .day, value: -days, to: cutoff) else { return nil }
        let rows = trips.compactMap { trip -> Double? in
            guard let d = day(trip.date), d >= previousCutoff, d < cutoff else { return nil }
            return trip.totalAmount
        }
        return rows.isEmpty ? nil : rows.reduce(0, +)
    }

    private var insightText: String? {
        guard let previous = previousPeriodTotal, previous > 0, totalSpend > 0 else { return nil }
        let change = (totalSpend - previous) / previous
        let pct = Int((abs(change) * 100).rounded())
        guard pct >= 3 else { return "About the same as the previous period." }
        return change > 0
            ? "You spent \(pct)% more than the previous period."
            : "You spent \(pct)% less than the previous period."
    }

    // A small curated, coordinated palette (not real-world brand colors) so
    // the store split reads as one intentional design rather than clashing
    // with the green header. Assigned by first-appearance order over ALL
    // trips (not the filtered range) so a store keeps its color when the
    // range changes.
    private static let storePalette: [Color] = [
        Color(red: 0.11, green: 0.45, blue: 0.44),  // deep teal
        Color(red: 0.88, green: 0.47, blue: 0.34),  // terracotta
        Color(red: 0.36, green: 0.42, blue: 0.75),  // slate indigo
        Color(red: 0.91, green: 0.68, blue: 0.30),  // soft amber
        Color(red: 0.62, green: 0.36, blue: 0.62),  // dusty plum
    ]

    private var brandDomain: [String] {
        var seen: [String] = []
        for trip in trips where !seen.contains(trip.brand) {
            seen.append(trip.brand)
        }
        return seen
    }

    private var brandColors: [Color] {
        brandDomain.enumerated().map { Self.storePalette[$0.offset % Self.storePalette.count] }
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

    /// Fixed axis ceiling (data max + headroom) so the floating tooltip
    /// annotation never rescales the chart while scrubbing.
    private var chartYMax: Double {
        let maxTotal = dayTotals.map(\.total).max() ?? 0
        return max(maxTotal, 1) * 1.25
    }

    /// Trips within a day, ordered by `brandDomain` rather than API/scan
    /// order, so the stacked bar segments are always in the same order.
    private var stackedFilteredTrips: [(trip: ShoppingTrip, day: Date)] {
        let order = brandDomain
        return filteredTrips.sorted {
            (order.firstIndex(of: $0.trip.brand) ?? 0) < (order.firstIndex(of: $1.trip.brand) ?? 0)
        }
    }

    /// Chronological x-axis category domain — one slot per shop day, so bars
    /// sit shoulder-to-shoulder without gaps for the days nothing was bought.
    private var dayKeyDomain: [String] {
        dayTotals.map { dayKey($0.day) }
    }

    private var selectedEntry: (day: Date, total: Double)? {
        guard let selectedDayKey else { return nil }
        return dayTotals.first { dayKey($0.day) == selectedDayKey }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(TrendRange.allCases) { r in
                rangePickerButton(r)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.06), in: Capsule())
    }

    private func rangePickerButton(_ r: TrendRange) -> some View {
        let isSelected = range == r
        let textColor: Color = isSelected ? .primary : .secondary
        return Button {
            withAnimation(.snappy(duration: 0.25)) { range = r }
        } label: {
            Text(r.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white).opacity(isSelected ? 1 : 0))
        }
    }

    // MARK: - Stat cards

    private var statCards: some View {
        HStack(spacing: 0) {
            statColumn(title: "Total spend", value: currencyShort(totalSpend))
            Divider().frame(height: 40)
            statColumn(title: "Average per shop", value: averagePerShopDay.map { currencyShort($0) } ?? "—")
        }
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
    }

    private func statColumn(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title.weight(.heavy))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func insightCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 3)
    }

    // MARK: - Card container

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: - Charts

    private var tripsChart: some View {
        Chart {
            ForEach(stackedFilteredTrips, id: \.trip.id) { entry in
                BarMark(
                    x: .value("Day", dayKey(entry.day)),
                    y: .value("Spend", entry.trip.totalAmount ?? 0),
                    width: .ratio(0.6)
                )
                .foregroundStyle(by: .value("Store", entry.trip.brand))
                .cornerRadius(4)
                .opacity(selectedEntry == nil || dayKey(entry.day) == selectedDayKey ? 1 : 0.35)
            }

            if let selected = selectedEntry {
                // Runs from the very top of the plot (where the tooltip floats)
                // down to just short of the bar, rather than through it to the
                // axis — the bar's own height already reads as the value.
                RuleMark(
                    x: .value("Day", dayKey(selected.day)),
                    yStart: .value("Top", chartYMax),
                    yEnd: .value("Bottom", selected.total + chartYMax * 0.035)
                )
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.gray.opacity(0.6))
                .annotation(position: .top, spacing: 6) {
                    tooltip(for: selected)
                }
            }
        }
        .chartForegroundStyleScale(domain: brandDomain, range: brandColors)
        .chartXScale(domain: dayKeyDomain)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...chartYMax)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                if let d = value.as(Double.self) {
                    AxisValueLabel { Text(currencyShort(d)) }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plotFrame = geometry[proxy.plotAreaFrame]
                                let x = value.location.x - plotFrame.origin.x
                                guard x >= 0, x <= plotFrame.width, let key: String = proxy.value(atX: x) else { return }
                                if key != selectedDayKey {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                selectedDayKey = key
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.2)) { selectedDayKey = nil }
                            }
                    )
            }
        }
    }

    private func tooltip(for entry: (day: Date, total: Double)) -> some View {
        VStack(spacing: 2) {
            Text(entry.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(currencyShort(entry.total))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
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
                    HStack {
                        Text(group.day.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(currencyShort(group.trips.reduce(0) { $0 + ($1.totalAmount ?? 0) }))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(group.trips.enumerated()), id: \.element.id) { i, trip in
                            if i > 0 { Divider() }
                            NavigationLink {
                                TripReceiptView(householdId: householdId, receiptId: trip.id).environment(services)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(trip.brand)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        if trip.itemCount > 0 {
                                            Text("\(trip.itemCount) item\(trip.itemCount == 1 ? "" : "s")")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    if let total = trip.totalAmount {
                                        Text(currencyShort(total))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Formatting

    /// Page-level section title — deliberately bigger/bolder than the day
    /// sub-headers inside the trip log, so "Trips" doesn't read as just
    /// another day row.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
    }

    /// "$201" — rounded to the nearest dollar. Insight/trend numbers are about
    /// the shape of spending, not exact cents, so cents are dropped everywhere
    /// on this page (unlike product-level detail, where they matter).
    private func currencyShort(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD").precision(.fractionLength(0)))
    }
}
