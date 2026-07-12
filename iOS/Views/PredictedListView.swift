import SwiftUI

/// Products likely due for a re-buy in the next 7 days, based on each
/// product's typical shopping-trip cadence, with an estimated cost.
struct PredictedListView: View {
    let householdId: String
    @Environment(AppServices.self) private var services

    @State private var response: PredictedListResponse? = nil
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

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
                    description: Text("Scan a few more receipts and we'll start predicting what you'll need this week.")
                )
            } else if let response {
                List {
                    Section {
                        summaryCard(response)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        ForEach(response.items) { item in
                            row(item)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.large)
        .task {
            do {
                response = try await services.api.fetchPredictedList(householdId: householdId)
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    // MARK: - Summary

    private func summaryCard(_ response: PredictedListResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREDICTED FOR THIS WEEK")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(currency(response.predictedTotal))
                .font(.largeTitle.weight(.bold))
            Text("^[\(response.items.count) item](inflect: true) likely due through \(displayDate(response.range.end))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                Text("\(dueLabel(item.predictedDate)) · every \(item.avgIntervalDays) day\(item.avgIntervalDays == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let price = item.predictedPrice {
                Text(currency(price))
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD"))
    }

    private func parseDay(_ day: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    private func displayDate(_ day: String) -> String {
        guard let d = parseDay(day) else { return day }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private func dueLabel(_ day: String) -> String {
        guard let d = parseDay(day) else { return day }
        let calendar = Calendar.current
        let daysFromToday = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: d).day ?? 0
        switch daysFromToday {
        case ..<0: return "Overdue"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default:
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return "Due \(f.string(from: d))"
        }
    }
}
