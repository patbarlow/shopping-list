import SwiftUI

/// Fixing what the scan got wrong, opened from the printed receipt.
///
/// Every row is already correct as far as the scan knows, so this is a
/// confirmation screen rather than a form: tap a row to include or exclude it,
/// tap the name to link it to a different product, correct a quantity or price
/// where the receipt was misread. Closing it returns to the paper, which
/// reprints with whatever changed.
struct ReceiptEditSheet: View {
    @Binding var items: [EditableReceiptItem]
    let storeName: String?
    let receiptTotal: Double?
    let printedItemCount: Int?
    let needsReview: Bool
    let householdId: String

    @Environment(\.dismiss) private var dismiss
    @State private var showProductPicker = false
    @State private var pickingForItemId: String? = nil
    @State private var productPickerQuery: String = ""
    @FocusState private var focusedPrice: String?

    private var includedItems: [EditableReceiptItem] { items.filter(\.isIncluded) }

    private var includedTotal: Double {
        includedItems.reduce(0) { $0 + (Double($1.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0) }
    }

    /// Units, not rows — a "×2" line counts twice, the way a receipt's own
    /// "8 Items" footer counts. A weighed line is one item whatever it weighs.
    private var includedUnitCount: Int {
        includedItems.reduce(0) { total, item in
            guard let q = item.quantity, q > 0, q == q.rounded() else { return total + 1 }
            return total + Int(q)
        }
    }

    private var newCount: Int { includedItems.filter { $0.productId == nil }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    summary
                    itemList
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(storeName ?? "Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { focusedPrice = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showProductPicker) {
            ProductPickerSheet(householdId: householdId, initialQuery: productPickerQuery) { result in
                applyPickerResult(result)
                showProductPicker = false
            }
        }
    }

    // MARK: - Summary

    /// What will be saved, against what the receipt itself says — the one place
    /// a missed line or a mis-read quantity shows up as a number that disagrees.
    private var summary: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(includedTotal, format: .currency(code: "AUD"))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .contentTransition(.numericText())
                    Text("^[\(includedUnitCount) item](inflect: true) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let receiptTotal {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(receiptTotal, format: .currency(code: "AUD"))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("on the receipt")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)

            if let mismatch = mismatchNote {
                Divider().padding(.leading, 16)
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mismatchNote: String? {
        if let printedItemCount, printedItemCount != includedUnitCount {
            return "The receipt counts \(printedItemCount) items, this adds up to \(includedUnitCount). Check the quantities."
        }
        if let receiptTotal, abs(receiptTotal - includedTotal) > 0.015, items.allSatisfy(\.isIncluded) {
            return "These don't add up to the receipt total. Check for a missed line or a wrong price."
        }
        if needsReview {
            return "Some of this receipt's numbers didn't add up. Worth a look before saving."
        }
        return nil
    }

    // MARK: - Items

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                itemRow(item: $item)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func itemRow(item: Binding<EditableReceiptItem>) -> some View {
        let value = item.wrappedValue
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Included or not. A checkmark, not a switch: these are things
                // being taken from the receipt, not settings being changed.
                Button {
                    item.isIncluded.wrappedValue.toggle()
                } label: {
                    Image(systemName: value.isIncluded ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(value.isIncluded ? Color.accentColor : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    // Tapping the name is how you link it to another product.
                    Button {
                        pickingForItemId = value.id
                        productPickerQuery = value.productName
                        showProductPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(value.productName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if value.productId == nil {
                                Text("NEW")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Text(value.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                HStack(spacing: 1) {
                    Text("$").foregroundStyle(.secondary)
                    TextField("0.00", text: item.priceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                        .focused($focusedPrice, equals: value.id)
                }
                .font(.body.weight(.medium))
                .monospacedDigit()
            }

            if value.isUnitCount || value.needsReview {
                quantityRow(item: item)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(value.isIncluded ? 1 : 0.45)
        .contentShape(Rectangle())
    }

    /// Quantity as a stepper, with the arithmetic it came from spelled out —
    /// a multi-buy landing on the wrong product is only obvious next to its price.
    private func quantityRow(item: Binding<EditableReceiptItem>) -> some View {
        let value = item.wrappedValue
        let quantity = value.quantity ?? 1
        return HStack(spacing: 10) {
            if value.isUnitCount {
                HStack(spacing: 0) {
                    stepperButton("minus", enabled: quantity > 1) {
                        setQuantity(quantity - 1, on: item)
                    }
                    Text("\(Int(quantity))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 28)
                    stepperButton("plus", enabled: quantity < 99) {
                        setQuantity(quantity + 1, on: item)
                    }
                }
                .background(Color(.tertiarySystemFill), in: Capsule())
            }

            if let detail = value.quantityDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(value.needsReview ? Color.orange : Color.secondary)
            }

            if value.needsReview {
                Text("didn't match the printed price")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.leading, 40)
    }

    private func stepperButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
    }

    /// A corrected count re-derives the unit price from what was paid, so the
    /// $/100g baseline the server computes stays consistent with the line.
    private func setQuantity(_ quantity: Double, on item: Binding<EditableReceiptItem>) {
        item.wrappedValue.quantity = quantity
        let paid = Double(item.wrappedValue.priceText.replacingOccurrences(of: ",", with: "."))
        item.wrappedValue.unitPrice = paid.map { $0 / max(quantity, 1) }
        item.wrappedValue.needsReview = false
    }

    private var footnote: some View {
        Text(newCount > 0
             ? "^[\(newCount) product](inflect: true) will be added to your list. Tap a name to link it to one you already have."
             : "Tap a name to link a line to a different product.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Picker result

    private func applyPickerResult(_ result: ProductPickerResult) {
        guard let itemId = pickingForItemId,
              let idx = items.firstIndex(where: { $0.id == itemId }) else {
            pickingForItemId = nil
            return
        }
        switch result {
        case .existing(let id, let name):
            items[idx].productId = id
            items[idx].productName = name
            items[idx].isNew = false
        case .create(let name):
            items[idx].productId = nil
            items[idx].productName = name
            items[idx].isNew = true
        }
        // A manual choice no longer maps to the auto-detected list entry.
        items[idx].purchaseHistoryId = nil
        items[idx].isIncluded = true
        pickingForItemId = nil
    }
}
