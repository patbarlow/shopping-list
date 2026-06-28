import SwiftUI
import PhotosUI
import PDFKit

struct ReceiptScannerView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case capture
        case scanning
        case review
        case confirming
        case done(String)
    }

    @State private var phase: Phase = .capture
    @State private var scanResult: ReceiptScanResponse? = nil
    @State private var editableMatches: [EditableReceiptMatch] = []
    @State private var editableUnmatched: [EditableUnmatchedItem] = []
    @State private var errorMessage: String? = nil

    // Product picker sheet state
    @State private var showProductPicker = false
    @State private var pickingForMatchId: String? = nil
    @State private var pickingForUnmatchedId: String? = nil
    @State private var productPickerQuery: String = ""

    @State var selectedPhoto: PhotosPickerItem? = nil
    @State var showCamera = false
    @State var showFilePicker = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .capture:         captureView
                case .scanning:        loadingView("Reading receipt…")
                case .review:          reviewView
                case .confirming:      loadingView("Saving…")
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
                        Button("Save") { confirmReceipt() }.bold()
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
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                Task { await handlePDF(data) }
            }
        }
        .sheet(isPresented: $showProductPicker) {
            ProductPickerSheet(householdId: householdId, initialQuery: productPickerQuery) { result in
                applyPickerResult(result)
                showProductPicker = false
            }
        }
        .task {
            if let pdf = services.pendingReceiptPDF {
                services.pendingReceiptPDF = nil
                await handlePDF(pdf)
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

    // MARK: - Capture (source selection)

    private var captureView: some View {
        List {
            Section {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Button {
                    showFilePicker = true
                } label: {
                    Label("Files (PDF)", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Choose a source")
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
                    Text("Tap a product name to correct the match.")
                }
            }

            if !editableUnmatched.isEmpty {
                Section {
                    ForEach($editableUnmatched) { $item in
                        unmatchedRow(item: $item)
                    }
                } header: {
                    Text("Not on your list")
                } footer: {
                    Text("Tap an item to track it.")
                }
            }
        }
    }

    @ViewBuilder
    private func matchRow(match: Binding<EditableReceiptMatch>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: match.isIncluded).labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    pickingForMatchId = match.wrappedValue.id
                    pickingForUnmatchedId = nil
                    productPickerQuery = match.wrappedValue.receiptDescription
                    showProductPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(match.wrappedValue.displayProductName)
                            .bold()
                            .foregroundStyle(.primary)
                        if match.wrappedValue.correctedProductId != nil {
                            Image(systemName: "pencil.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Text(match.wrappedValue.receiptDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField("0.00", text: match.priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
            }
        }
        .opacity(match.wrappedValue.isIncluded ? 1 : 0.4)
    }

    @ViewBuilder
    private func unmatchedRow(item: Binding<EditableUnmatchedItem>) -> some View {
        Button {
            pickingForUnmatchedId = item.wrappedValue.id
            pickingForMatchId = nil
            productPickerQuery = item.wrappedValue.description
            showProductPicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = item.wrappedValue.resolution.resolvedName {
                        Text(name).bold().foregroundStyle(.primary)
                        Text(item.wrappedValue.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.wrappedValue.description).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let price = item.wrappedValue.totalPrice {
                    Text(String(format: "$%.2f", price))
                        .foregroundStyle(item.wrappedValue.resolution.isIgnore ? .secondary : .primary)
                        .font(.footnote)
                }
                if !item.wrappedValue.resolution.isIgnore {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Done

    private func doneView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(message).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Picker result

    private func applyPickerResult(_ result: ProductPickerResult) {
        if let matchId = pickingForMatchId,
           let idx = editableMatches.firstIndex(where: { $0.id == matchId }) {
            switch result {
            case .existing(let id, let name):
                editableMatches[idx].correctedProductId = id
                editableMatches[idx].correctedProductName = name
            case .create(let name):
                editableMatches[idx].correctedProductId = "__new__"
                editableMatches[idx].correctedProductName = name
            }
        } else if let unmatchedId = pickingForUnmatchedId,
                  let idx = editableUnmatched.firstIndex(where: { $0.id == unmatchedId }) {
            switch result {
            case .existing(let id, let name):
                editableUnmatched[idx].resolution = .assignExisting(productId: id, name: name)
            case .create(let name):
                editableUnmatched[idx].resolution = .createNew(name: name)
            }
        }
        pickingForMatchId = nil
        pickingForUnmatchedId = nil
    }

    // MARK: - Image handling

    private func handlePDF(_ pdfData: Data) async {
        phase = .scanning
        errorMessage = nil
        do {
            guard let image = renderPDFToImage(pdfData) else {
                phase = .capture; errorMessage = "Couldn't read that PDF."; return
            }
            guard let compressed = image.compressedForUpload() else {
                phase = .capture; errorMessage = "Image error."; return
            }
            let result = try await services.api.scanReceipt(
                householdId: householdId,
                imageBase64: compressed.base64EncodedString()
            )
            applyResult(result)
        } catch {
            phase = .capture
            errorMessage = "Couldn't read that receipt."
        }
    }

    private func renderPDFToImage(_ data: Data) -> UIImage? {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }

        let scale: CGFloat = 2.0
        var images: [UIImage] = []

        for i in 0 ..< doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pageSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

            UIGraphicsBeginImageContextWithOptions(pageSize, true, 1.0)
            defer { UIGraphicsEndImageContext() }
            guard let ctx = UIGraphicsGetCurrentContext() else { continue }

            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: pageSize))
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx)

            if let img = UIGraphicsGetImageFromCurrentImageContext() {
                images.append(img)
            }
        }

        guard !images.isEmpty else { return nil }
        if images.count == 1 { return images[0] }

        let totalHeight = images.reduce(0) { $0 + $1.size.height }
        let width = images.map(\.size.width).max() ?? 0
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: totalHeight), true, 1.0)
        defer { UIGraphicsEndImageContext() }
        var y: CGFloat = 0
        for img in images { img.draw(at: CGPoint(x: 0, y: y)); y += img.size.height }
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        phase = .scanning
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let compressed = image.compressedForUpload()
            else { phase = .capture; errorMessage = "Couldn't load that photo."; return }
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: compressed.base64EncodedString())
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
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: compressed.base64EncodedString())
            applyResult(result)
        } catch {
            phase = .capture
            errorMessage = "Couldn't read that receipt."
        }
    }

    private func applyResult(_ result: ReceiptScanResponse) {
        scanResult = result
        editableMatches = result.matches.map { EditableReceiptMatch(from: $0) }
        editableUnmatched = result.unmatched.enumerated().map { i, item in
            EditableUnmatchedItem(
                id: "\(i)-\(item.description)",
                description: item.description,
                totalPrice: item.totalPrice ?? item.unitPrice
            )
        }
        phase = .review
    }

    // MARK: - Confirm

    private func confirmReceipt() {
        guard case .review = phase, let result = scanResult else { return }
        phase = .confirming

        let confirmedMatches: [[String: Any]] = editableMatches
            .filter { $0.isIncluded && $0.correctedProductId == nil }
            .compactMap { match in
                guard let price = Double(match.priceText.replacingOccurrences(of: ",", with: ".")) else { return nil }
                return [
                    "purchase_history_id": match.purchaseHistoryId,
                    "price_paid": price,
                    "receipt_description": match.receiptDescription,
                    "product_id": match.productId,
                ]
            }

        let corrections: [[String: Any]] = editableMatches
            .filter { $0.isIncluded && $0.correctedProductId != nil }
            .compactMap { match in
                guard let price = Double(match.priceText.replacingOccurrences(of: ",", with: ".")),
                      let correctedId = match.correctedProductId,
                      let correctedName = match.correctedProductName else { return nil }
                if correctedId == "__new__" {
                    return ["receipt_description": match.receiptDescription, "new_product_name": correctedName, "price_paid": price]
                } else {
                    return ["receipt_description": match.receiptDescription, "product_id": correctedId, "price_paid": price]
                }
            }

        let unplanned: [[String: Any]] = editableUnmatched.compactMap { item in
            let price = item.totalPrice ?? 0
            switch item.resolution {
            case .ignore: return nil
            case .assignExisting(let id, _):
                return ["receipt_description": item.description, "product_id": id, "price_paid": price]
            case .createNew(let name):
                return ["receipt_description": item.description, "new_product_name": name, "price_paid": price]
            }
        }

        Task {
            do {
                try await services.api.confirmReceipt(
                    householdId: householdId,
                    storeName: result.storeName,
                    totalAmount: result.totalAmount,
                    receiptDate: result.receiptDate,
                    matches: confirmedMatches,
                    corrections: corrections,
                    unplanned: unplanned
                )
                let savedCount = confirmedMatches.count + corrections.count + unplanned.count
                phase = .done("Tracked \(savedCount) item\(savedCount == 1 ? "" : "s").")
            } catch {
                phase = .review
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Product Picker Sheet

struct ProductPickerSheet: View {
    let householdId: String
    let initialQuery: String
    let onSelect: (ProductPickerResult) -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var results: [ProductSearchResult] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results) { product in
                    Button {
                        onSelect(.existing(id: product.id, name: product.name))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name)
                            Text(product.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        onSelect(.create(name: searchText.trimmingCharacters(in: .whitespaces)))
                    } label: {
                        Label("Add \"\(searchText.trimmingCharacters(in: .whitespaces))\"", systemImage: "plus.circle")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search products")
            .navigationTitle("Choose Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { searchText = initialQuery }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                isLoading = true
                let found = (try? await services.api.searchProducts(householdId: householdId, query: query)) ?? []
                guard !Task.isCancelled else { isLoading = false; return }
                results = found
                isLoading = false
            }
        }
    }
}
