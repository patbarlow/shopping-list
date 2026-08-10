import SwiftUI

/// One scanned receipt, rendered like the paper original — line items, a
/// dashed rule, and the total — pushed from a trip row in Spend Trends.
struct TripReceiptView: View {
    let householdId: String
    let receiptId: String
    @Environment(AppServices.self) private var services

    @State private var receipt: ReceiptSummary? = nil
    @State private var items: [ReceiptLineItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load receipt", systemImage: "receipt", description: Text(errorMessage))
            } else {
                ScrollView {
                    receiptCard
                        .padding(20)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(receipt?.storeName ?? "Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let response = try await services.api.fetchReceipt(householdId: householdId, receiptId: receiptId)
                receipt = response.receipt
                items = response.items
            } catch {
                errorMessage = "Please try again."
            }
            isLoading = false
        }
    }

    private var receiptCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(receipt?.storeName ?? "Receipt")
                    .font(.system(.headline, design: .monospaced).weight(.bold))
                    .multilineTextAlignment(.center)
                if let receipt, let date = Self.dayFormatter.date(from: receipt.date) {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 14)
            .padding(.horizontal, 16)

            dashedDivider

            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.rawDescription)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let price = item.totalPrice {
                            Text(price, format: .currency(code: "AUD"))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 16)

            dashedDivider

            HStack {
                Text("TOTAL")
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                Spacer()
                if let total = receipt?.totalAmount {
                    Text(total, format: .currency(code: "AUD"))
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if !items.isEmpty {
                Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 20)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }

    private var dashedDivider: some View {
        HStack(spacing: 4) {
            ForEach(0..<44, id: \.self) { _ in
                Rectangle().frame(width: 3, height: 1)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
