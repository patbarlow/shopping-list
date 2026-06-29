import SwiftUI

struct HistoryDayView: View {
    let householdId: String
    let date: String
    let onBack: () -> Void

    @Environment(AppServices.self) private var services
    @State private var items: [HistoryItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showReceiptScanner = false

    private var displayDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: d)
    }

    private var groupedItems: [(category: ItemCategory, items: [HistoryItem])] {
        let grouped = Dictionary(grouping: items) { ItemCategory(rawValue: $0.category) ?? .other }
        return grouped
            .sorted { $0.key.aisleOrder < $1.key.aisleOrder }
            .map { (category: $0.key, items: $0.value.sorted { $0.productName < $1.productName }) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else if let err = errorMessage {
                        Text(err)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else if items.isEmpty {
                        Text("No items recorded for this day.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(groupedItems, id: \.category) { group in
                            categoryCard(group: group)
                        }
                    }
                    Color.clear.frame(height: 100)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            
            // Upload Receipt Button (Replaces Add Item)
            uploadButton
                .padding(.bottom, 20)
        }
        .navigationTitle(displayDate)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showReceiptScanner) {
            ReceiptScannerView(householdId: householdId).environment(services)
        }
        // Keyed on `date` so switching days reloads — a plain .task does not re-run
        // when only the date value changes and the view instance is reused.
        .task(id: date) {
            isLoading = true
            errorMessage = nil
            do {
                items = try await services.api.fetchHistoryDay(householdId: householdId, date: date)
            } catch {
                if !Task.isCancelled { errorMessage = "Couldn't load items" }
            }
            isLoading = false
        }
    }

    private var uploadButton: some View {
        Button {
            showReceiptScanner = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.body.weight(.semibold))
                Text("Upload Receipt")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        }
    }

    private func categoryCard(group: (category: ItemCategory, items: [HistoryItem])) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(group.category.emoji)
                    .font(.title3)
                    .frame(width: 28)
                Text(group.category.rawValue)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(group.category.color)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 14).opacity(0.2)

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 52).opacity(0.15)
                }
                itemRow(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .padding(.bottom, 4)
        }
        .background(group.category.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func itemRow(_ item: HistoryItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
                .frame(width: 28, height: 28)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.productName)
                    .foregroundStyle(.secondary)
                if let qty = item.quantity, !qty.isEmpty {
                    Text(qty)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let price = item.pricePaid {
                Text(String(format: "$%.2f", price))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
