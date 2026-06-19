import SwiftUI
import PhotosUI

struct ReceiptScannerView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case capture
        case scanning
        case review
        case confirming
        case done(String)   // success message
    }

    @State private var phase: Phase = .capture
    @State private var scanResult: ReceiptScanResponse? = nil
    @State private var editableMatches: [EditableReceiptMatch] = []
    @State private var unmatchedItems: [ReceiptLineItemResponse] = []
    @State private var errorMessage: String? = nil
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .capture:         captureView
                case .scanning:        loadingView("Reading receipt…")
                case .review:          reviewView
                case .confirming:      loadingView("Saving prices…")
                case .done(let msg):   doneView(msg)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if case .review = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { confirmReceipt() }
                            .bold()
                    }
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await handlePhotoSelection(item) }
        }
        .sheet(isPresented: $showCamera) {
            CameraCapture { image in
                showCamera = false
                Task { await handleCapturedImage(image) }
            }
        }
    }

    private var navTitle: String {
        switch phase {
        case .capture:    return "Scan Receipt"
        case .scanning:   return "Scanning…"
        case .review:     return scanResult?.storeName ?? "Match Items"
        case .confirming: return "Saving…"
        case .done:       return "Done"
        }
    }

    // MARK: - Capture

    private var captureView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photograph your receipt to match prices with recently purchased items.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Loading

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private var reviewView: some View {
        List {
            if let result = scanResult, result.totalAmount != nil || result.storeName != nil {
                Section {
                    if let store = result.storeName {
                        LabeledContent("Store", value: store)
                    }
                    if let total = result.totalAmount {
                        LabeledContent("Total", value: String(format: "$%.2f", total))
                    }
                }
            }

            if !editableMatches.isEmpty {
                Section {
                    ForEach($editableMatches) { $match in
                        matchRow(match: $match)
                    }
                } header: {
                    Text("Matched items")
                } footer: {
                    Text("Toggle off items you don't want to save prices for.")
                }
            }

            if !unmatchedItems.isEmpty {
                Section {
                    ForEach(unmatchedItems) { item in
                        HStack {
                            Text(item.description)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let price = item.totalPrice ?? item.unitPrice {
                                Text(String(format: "$%.2f", price))
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text("Unmatched items")
                } footer: {
                    Text("These receipt items couldn't be matched to recent purchases.")
                }
            }
        }
    }

    @ViewBuilder
    private func matchRow(match: Binding<EditableReceiptMatch>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: match.isIncluded)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(match.wrappedValue.productName)
                    .bold()
                Text(match.wrappedValue.receiptDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 2) {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("0.00", text: match.priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
            }
        }
        .opacity(match.wrappedValue.isIncluded ? 1 : 0.4)
    }

    // MARK: - Done

    private func doneView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(message)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        phase = .scanning
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let compressed = image.compressedForUpload()
            else {
                phase = .capture
                errorMessage = "Couldn't load that photo."
                return
            }
            let base64 = compressed.base64EncodedString()
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: base64)
            applyResult(result)
        } catch {
            phase = .capture
            errorMessage = "Couldn't read that receipt."
        }
    }

    private func handleCapturedImage(_ image: UIImage) async {
        phase = .scanning
        errorMessage = nil
        do {
            guard let compressed = image.compressedForUpload() else {
                phase = .capture; errorMessage = "Image error."; return
            }
            let base64 = compressed.base64EncodedString()
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: base64)
            applyResult(result)
        } catch {
            phase = .capture
            errorMessage = "Couldn't read that receipt."
        }
    }

    private func applyResult(_ result: ReceiptScanResponse) {
        scanResult     = result
        editableMatches = result.matches.map { EditableReceiptMatch(from: $0) }
        unmatchedItems  = result.unmatched
        phase           = .review
    }

    private func confirmReceipt() {
        guard case .review = phase, let result = scanResult else { return }
        phase = .confirming

        let confirmedMatches: [[String: Any]] = editableMatches
            .filter { $0.isIncluded }
            .compactMap { match in
                guard let price = Double(match.priceText.replacingOccurrences(of: ",", with: ".")) else { return nil }
                return ["purchase_history_id": match.purchaseHistoryId, "price_paid": price]
            }

        Task {
            do {
                try await services.api.confirmReceipt(
                    householdId: householdId,
                    storeName: result.storeName,
                    totalAmount: result.totalAmount,
                    matches: confirmedMatches
                )
                let savedCount = confirmedMatches.count
                phase = .done("Saved prices for \(savedCount) item\(savedCount == 1 ? "" : "s").")
            } catch {
                phase = .review
                errorMessage = error.localizedDescription
            }
        }
    }
}
