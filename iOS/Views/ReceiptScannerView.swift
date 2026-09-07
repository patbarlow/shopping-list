import SwiftUI
import PDFKit
import VisionKit

struct ReceiptScannerView: View {
    let householdId: String
    let initialCapture: InitialCapture
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Content already captured by the caller (native picker triggered directly
    /// from the toolbar menu — see ReceiptImportToolbarButton) before this view
    /// is ever presented, so it can open straight into `.scanning` instead of
    /// showing its own "choose a source" step as a second card on top.
    // A struct (not a bare enum) specifically so it can carry a stable `id` —
    // `.sheet(item:)` keys the presented view's identity off it, and giving
    // every capture its own fresh id (even two `.photoData` in a row that
    // would otherwise look alike) is what guarantees each presentation gets
    // genuinely new state instead of possibly reusing a stale prior one.
    struct InitialCapture: Identifiable {
        let id = UUID()
        let payload: Payload

        enum Payload {
            case images([UIImage])
            case photoData(Data)
            case pdfData(Data)
        }

        static func images(_ images: [UIImage]) -> InitialCapture { InitialCapture(payload: .images(images)) }
        static func photoData(_ data: Data) -> InitialCapture { InitialCapture(payload: .photoData(data)) }
        static func pdfData(_ data: Data) -> InitialCapture { InitialCapture(payload: .pdfData(data)) }
    }

    private enum Phase {
        case failed
        case scanning
        case printing
        case review
        case confirming
    }

    @State private var phase: Phase = .scanning
    @State private var scanResult: ReceiptScanResponse? = nil
    @State private var editableItems: [EditableReceiptItem] = []
    @State private var errorMessage: String? = nil

    // Product picker sheet state
    @State private var showEditor = false
    @State private var showSaveError = false
    @State private var showProductPicker = false
    @State private var pickingForItemId: String? = nil
    @State private var productPickerQuery: String = ""

    // Belt-and-braces: guarantees the scan request only ever fires once for
    // this instance even if `.task` were somehow re-entered — a request that
    // fired twice showed up as one seeing itself fail (its response arriving
    // after this view had already moved on with the other's) right before
    // the real one completed normally.
    @State private var hasStartedProcessing = false

    init(householdId: String, initialCapture: InitialCapture) {
        self.householdId = householdId
        self.initialCapture = initialCapture
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .failed:                failedView
                default:
                    ReceiptPrinterView(
                        result: scanResult,
                        items: editableItems,
                        isReady: isReady,
                        isSaving: isSaving,
                        onFinished: { phase = .review },
                        onEdit: { showEditor = true },
                        onTear: confirmReceipt
                    )
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }

            }
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                reviewView
                    .navigationTitle("Review items")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showEditor = false }.bold()
                        }
                    }
            }
        }

        .alert("Receipt wasn’t saved", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try confirming the receipt again.")
        }
        .task {
            guard !hasStartedProcessing else { return }
            hasStartedProcessing = true
            // The AI parse this kicks off can take a real while (up to the
            // 120s request timeout) — long enough that locking the phone or
            // swiping to another app mid-scan is a completely normal thing
            // for someone to do while waiting. Without a background task,
            // iOS suspends the app almost immediately and the in-flight
            // request gets torn down, which surfaced as a plain "cancelled"
            // error with no obvious cause. This buys it room to finish.
            let bgTask = UIApplication.shared.beginBackgroundTask(withName: "ReceiptScan")
            await process(initialCapture)
            UIApplication.shared.endBackgroundTask(bgTask)
        }
    }

    private func process(_ capture: InitialCapture) async {
        switch capture.payload {
        case .images(let images):  await handleScannedPages(images)
        case .photoData(let data): await handlePhotoData(data)
        case .pdfData(let data):   await handlePDF(data)
        }
    }

    private var isReady: Bool {
        if case .review = phase { return true }
        return false
    }

    private var isSaving: Bool {
        if case .confirming = phase { return true }
        return false
    }

    private var navTitle: String {
        switch phase {
        case .failed:     return "Couldn't Read Receipt"
        case .scanning:   return "Scanning…"
        case .printing:   return scanResult?.storeName ?? "Reading Receipt…"
        case .review:     return scanResult?.storeName ?? "Match Items"
        case .confirming: return "Saving…"
        }
    }

    // MARK: - Failure

    private var failedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(errorMessage ?? "Something went wrong.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private var includedCount: Int { editableItems.filter(\.isIncluded).count }
    private var newCount: Int { editableItems.filter { $0.isIncluded && $0.productId == nil }.count }

    private var reviewView: some View {
        ReceiptEditorView(items: $editableItems, householdId: householdId)
    }

    // MARK: - Image handling

    private func handlePDF(_ pdfData: Data) async {
        phase = .scanning
        errorMessage = nil

        // 1. Prefer the PDF's text layer — most accurate for digital eReceipts.
        //    If extraction is garbled or the server can't parse it, fall through to image OCR.
        if let text = extractReceiptText(pdfData),
           let result = try? await services.api.scanReceipt(householdId: householdId, receiptText: text) {
            applyResult(result)
            return
        }

        // 2. Fall back to rasterising the PDF and reading it as an image.
        do {
            guard let image = renderPDFToImage(pdfData) else {
                phase = .failed; errorMessage = "Couldn't read that PDF."; return
            }
            guard let compressed = image.compressedForUpload() else {
                phase = .failed; errorMessage = "Image error."; return
            }
            let result = try await services.api.scanReceipt(
                householdId: householdId,
                imageBase64: compressed.base64EncodedString()
            )
            applyResult(result)
        } catch {
            phase = .failed
            errorMessage = "Couldn't read that receipt. (\(error.localizedDescription))"
        }
    }

    /// Pull the embedded text layer from a PDF, returning it only if it looks like
    /// genuine receipt text (enough readable characters and at least one price/number).
    private func extractReceiptText(_ data: Data) -> String? {
        guard let doc = PDFDocument(data: data) else { return nil }
        var text = ""
        for i in 0 ..< doc.pageCount {
            if let page = doc.page(at: i) { text += layoutText(for: page) + "\n" }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40, trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        // Guard against CID/garbled extraction: require a high ratio of readable characters.
        let readableSet = CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "$€£¢"))
        let readable = trimmed.unicodeScalars.filter { readableSet.contains($0) }.count
        guard Double(readable) / Double(trimmed.unicodeScalars.count) >= 0.85 else { return nil }
        return trimmed
    }

    /// Rebuild a page's text in visual order. `PDFPage.string` returns text in
    /// content-stream order, which on two-column receipts emits all descriptions and
    /// then all prices as separate runs — so prices end up paired with the wrong items.
    /// Regrouping the line fragments by baseline puts each price back on its item's line.
    private func layoutText(for page: PDFPage) -> String {
        guard let full = page.selection(for: page.bounds(for: .mediaBox)) else {
            return page.string ?? ""
        }
        struct Fragment {
            let x: CGFloat
            let y: CGFloat
            let text: String
        }
        var fragments: [Fragment] = []
        for line in full.selectionsByLine() {
            guard let t = line.string?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { continue }
            let b = line.bounds(for: page)
            fragments.append(Fragment(x: b.minX, y: b.midY, text: t))
        }
        guard !fragments.isEmpty else { return page.string ?? "" }

        var rows: [(y: CGFloat, frags: [Fragment])] = []
        for f in fragments.sorted(by: { $0.y > $1.y }) {
            if let last = rows.indices.last, abs(rows[last].y - f.y) < 3 {
                rows[last].frags.append(f)
            } else {
                rows.append((f.y, [f]))
            }
        }
        return rows
            .map { $0.frags.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
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

    private func handlePhotoData(_ data: Data) async {
        phase = .scanning
        errorMessage = nil
        do {
            guard let image = UIImage(data: data),
                  let compressed = image.compressedForUpload()
            else { phase = .failed; errorMessage = "Couldn't load that photo."; return }
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: compressed.base64EncodedString())
            applyResult(result)
        } catch {
            phase = .failed
            errorMessage = "Couldn't read that receipt. (\(error.localizedDescription))"
        }
    }

    /// The document scanner can return more than one page (a long receipt
    /// scanned in sections) — stitch them into one tall image, same as the
    /// multi-page PDF path below.
    private func handleScannedPages(_ images: [UIImage]) async {
        phase = .scanning
        errorMessage = nil
        guard let stitched = images.count > 1 ? stitchVertically(images) : images.first else {
            phase = .failed; errorMessage = "Couldn't read that scan."; return
        }
        do {
            guard let compressed = stitched.compressedForUpload() else {
                phase = .failed; errorMessage = "Image error."; return
            }
            let result = try await services.api.scanReceipt(householdId: householdId, imageBase64: compressed.base64EncodedString())
            applyResult(result)
        } catch {
            phase = .failed
            errorMessage = "Couldn't read that receipt. (\(error.localizedDescription))"
        }
    }

    private func stitchVertically(_ images: [UIImage]) -> UIImage? {
        let width = images.map(\.size.width).max() ?? 0
        let totalHeight = images.reduce(0) { $0 + $1.size.height }
        guard width > 0, totalHeight > 0 else { return nil }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: totalHeight), true, 1.0)
        defer { UIGraphicsEndImageContext() }
        var y: CGFloat = 0
        for img in images { img.draw(at: CGPoint(x: 0, y: y)); y += img.size.height }
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    private func applyResult(_ result: ReceiptScanResponse) {
        scanResult = result
        editableItems = result.items.map { EditableReceiptItem(from: $0) }
        phase = .printing
    }

    // MARK: - Confirm

    private func confirmReceipt() {
        guard case .review = phase, let result = scanResult else { return }
        phase = .confirming

        let items: [[String: Any]] = editableItems
            .filter(\.isIncluded)
            .map { item in
                var dict: [String: Any] = ["receipt_description": item.description]
                if let id = item.productId {
                    dict["product_id"] = id
                } else {
                    dict["new_product_name"] = item.productName
                }
                if let phId = item.purchaseHistoryId { dict["purchase_history_id"] = phId }
                if let qty = item.quantity { dict["quantity"] = qty }
                if let price = Double(item.priceText.replacingOccurrences(of: ",", with: ".")) {
                    dict["price_paid"] = price
                }
                if let unitPrice = item.unitPrice { dict["unit_price"] = unitPrice }
                if let sizeValue = item.sizeValue { dict["size_value"] = sizeValue }
                if let sizeUnit = item.sizeUnit { dict["size_unit"] = sizeUnit }
                return dict
            }

        Task {
            do {
                try await services.api.confirmReceipt(
                    householdId: householdId,
                    storeName: result.storeName,
                    totalAmount: result.totalAmount,
                    receiptDate: result.receiptDate,
                    items: items
                )
                dismiss()
            } catch {
                phase = .review
                errorMessage = error.localizedDescription
                showSaveError = true
            }
        }
    }
}

// MARK: - Document scanner

/// Wraps VisionKit's document scanner — the same "Scan Documents" UI as
/// Files/Notes: automatic edge detection in the camera, then crop/filter
/// before finishing, optionally across multiple pages.
struct DocumentScannerCapture: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void
        // Delegate callbacks on this controller have been seen firing more
        // than once for a single session (e.g. a finish followed by a stray
        // cancel/fail as it tears down) — this makes sure only the first one
        // is ever actually acted on.
        private var hasFired = false
        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        // Dismissal is left entirely to the SwiftUI `.fullScreenCover(isPresented:)`
        // binding (via onScan/onCancel below). Also calling `controller.dismiss`
        // here raced with that binding update and could tear down the wrong
        // presentation — most visibly, the *parent* sheet closing itself right
        // after a scan completed, before the review screen ever showed.
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard !hasFired else { return }
            hasFired = true
            var images: [UIImage] = []
            for i in 0..<scan.pageCount { images.append(scan.imageOfPage(at: i)) }
            onScan(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard !hasFired else { return }
            hasFired = true
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            guard !hasFired else { return }
            hasFired = true
            onCancel()
        }
    }
}

// MARK: - Receipt editor

private struct ReceiptEditorView: View {
    @Binding var items: [EditableReceiptItem]
    let householdId: String

    var body: some View {
        List {
            Section {
                ForEach($items) { $item in
                    HStack(spacing: 12) {
                        Button {
                            item.isIncluded.toggle()
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Image(systemName: item.isIncluded ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(item.isIncluded ? Color.accentColor : Color.secondary)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.isIncluded ? "Ignore" : "Include") \(item.description)")

                        NavigationLink {
                            ReceiptProductChoice(item: $item, householdId: householdId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(item.description).font(.subheadline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.priceText.isEmpty ? "—" : "$" + item.priceText)
                                        .font(.subheadline.monospacedDigit())
                                        .fixedSize()
                                }
                                Text(!item.isIncluded ? "Ignored" : item.productId == nil ? "New product · \(item.productName)" : "Matched to \(item.productName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .opacity(item.isIncluded ? 1 : 0.45)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("\(items.filter(\.isIncluded).count) of \(items.count) items included")
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct ReceiptProductChoice: View {
    @Binding var item: EditableReceiptItem
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ProductSearchResult] = []
    @State private var loading = false
    @State private var searchFailed = false
    @State private var creating = false
    @State private var newName = ""
    @State private var adjusting = false
    @State private var quantity = ""
    @State private var price = ""
    @State private var invalidDetails = false

    var body: some View {
        List {
            Section("On the receipt") {
                Text(item.description).font(.system(.subheadline, design: .monospaced))
                HStack {
                    Text(item.productName)
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            Section(query.isEmpty ? "Suggested products" : "Search results") {
                if loading { ProgressView() }
                if searchFailed {
                    Text("Couldn’t search products. Try another search.").foregroundStyle(.secondary)
                } else if !loading && results.isEmpty {
                    Text("No matching products. Search by another name or create a new product.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(results) { product in
                    Button {
                        item.productId = product.id
                        item.productName = product.name
                        item.isNew = false
                        item.purchaseHistoryId = nil
                        item.isIncluded = true
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(product.name).foregroundStyle(.primary)
                                Text(product.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if product.id == item.productId {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Create new product…", systemImage: "plus.circle") {
                    newName = item.productName
                    creating = true
                }
            }
            Section {
                Button("Adjust quantity or price", systemImage: "slider.horizontal.3") {
                    quantity = item.quantity.map { String($0) } ?? ""
                    price = item.priceText
                    adjusting = true
                }
                .font(.subheadline)
            }
        }
        .navigationTitle("Choose product")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search all your products")
        .task(id: query) {
            loading = true
            searchFailed = false
            do {
                try await Task.sleep(for: .milliseconds(200))
                let search = query.isEmpty ? item.productName : query
                let found = try await services.api.searchProducts(householdId: householdId, query: search)
                guard !Task.isCancelled else { return }
                results = found
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                loading = false
                searchFailed = true
            }
        }
        .alert("New product", isPresented: $creating) {
            TextField("Product name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Use new product") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                item.productId = nil
                item.productName = name
                item.isNew = true
                item.purchaseHistoryId = nil
                item.isIncluded = true
                dismiss()
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This product will be created when you confirm the receipt.")
        }
        .alert("Adjust receipt line", isPresented: $adjusting) {
            TextField("Quantity", text: $quantity).keyboardType(.decimalPad)
            TextField("Line price", text: $price).keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                let qty = Double(quantity.replacingOccurrences(of: ",", with: "."))
                let amount = Double(price.replacingOccurrences(of: ",", with: "."))
                guard (quantity.isEmpty || (qty != nil && qty!.isFinite && qty! > 0)),
                      (price.isEmpty || (amount != nil && amount!.isFinite)) else {
                    invalidDetails = true
                    return
                }
                item.quantity = qty
                item.priceText = amount.map { String(format: "%.2f", $0) } ?? ""
                // Original per-unit price is stale after a manual correction.
                item.unitPrice = nil
            }
        }
        .alert("Check quantity and price", isPresented: $invalidDetails) {
            Button("OK", role: .cancel) {}
        } message: { Text("Use a positive quantity and a valid price, or leave them blank.") }
    }
}

// MARK: - Thermal receipt printer

/// Paper feeds upwards from the slot; the complete assembly scrolls together.
/// The viewport, paper and printer
/// all derive their widths from the same bounded geometry, regardless of content.
private struct ReceiptPrinterView: View {
    let result: ReceiptScanResponse?
    let items: [EditableReceiptItem]
    let isReady: Bool
    let isSaving: Bool
    let onFinished: () -> Void
    let onEdit: () -> Void
    let onTear: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var printed = 0
    @State private var tearing = false
    @State private var detached = false
    @State private var feedHaptic = UIImpactFeedbackGenerator(style: .light)
    private let paper = Color.white
    private let ink = Color.black
    private var included: [EditableReceiptItem] { items.filter(\.isIncluded) }
    private var canTear: Bool { isReady && !included.isEmpty && !tearing && !detached }
    private var lineCount: Int { items.count + 2 }

    var body: some View {
        GeometryReader { geometry in
            let machineWidth = min(max(geometry.size.width - 32, 0), 370)
            let paperWidth = max(machineWidth - 48, 0)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        receipt(width: paperWidth)
                            .rotationEffect(.degrees(reduceMotion || !tearing || detached ? 0 : -3), anchor: .bottomLeading)
                            .offset(y: detached ? (reduceMotion ? 0 : -geometry.size.height - 200) : tearing ? -12 : 0)
                            .opacity(detached ? 0 : 1)
                            .zIndex(2)
                        printer(width: machineWidth, paperWidth: paperWidth)
                            .padding(.top, -8)
                        Color.clear.frame(height: 104).id("feed")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                .scrollIndicators(.hidden)
                .scrollDisabled(tearing || isSaving)
                .defaultScrollAnchor(.bottom)
                .onChange(of: printed) {
                    withAnimation(reduceMotion ? nil : .linear(duration: 0.18)) {
                        proxy.scrollTo("feed", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 12) {
                        if isReady && !tearing {
                            Button(action: onEdit) {
                                Label("Edit", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            Button {
                                proxy.scrollTo("feed", anchor: .bottom)
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                    tearing = true
                                }
                            } label: {
                                Label("Confirm", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(!canTear)
                        } else if !tearing && !isSaving {
                            ProgressView().controlSize(.small)
                            Text(result == nil ? "Reading receipt…" : "Printing…")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 370)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .background { Color(.systemGroupedBackground).ignoresSafeArea() }
        .task(id: tearing) {
            guard tearing else { return }
            do {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                try await Task.sleep(for: .milliseconds(180))
                withAnimation(reduceMotion ? .linear(duration: 0.15) : .easeIn(duration: 0.5)) {
                    detached = true
                }
                try await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 500))
                guard !Task.isCancelled else { return }
                onTear()
            } catch { }
        }
        .task(id: result != nil) {
            guard result != nil, printed == 0 else { return }
            feedHaptic.prepare()
            do {
                for line in 1...lineCount {
                    try await Task.sleep(for: .milliseconds(reduceMotion ? 35 : 210))
                    guard !Task.isCancelled else { return }
                    // Feed advances in physical steps; never interpolate the text layout.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { printed = line }
                    feedHaptic.impactOccurred(intensity: line == lineCount ? 0.7 : 0.35)
                    feedHaptic.prepare()
                }
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                onFinished()
            } catch { /* Dismissal cancels the feed without advancing the flow. */ }
        }
        .onChange(of: isSaving) { _, saving in
            if !saving { detached = false; tearing = false }
        }
    }

    private var displayDate: String? {
        guard let raw = result?.receiptDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(raw.prefix(10))) else { return raw }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func receipt(width: CGFloat) -> some View {
        let priceWidth = min(width * 0.42, max(56, CGFloat(items.map { $0.priceText.count + 1 }.max() ?? 6) * UIFont.preferredFont(forTextStyle: .footnote).pointSize * 0.62))
        return VStack(spacing: 0) {
            if printed > 0 {
                VStack(spacing: 4) {
                    Text(result?.storeName ?? "Your receipt")
                        .font(.system(.headline, design: .monospaced).bold())
                        .multilineTextAlignment(.center)
                    if let date = displayDate {
                        Text(date)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.45))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 14)
                rule
            }
            ForEach(Array(included.enumerated()), id: \.offset) { index, item in
                if isReady || isSaving || printed > index + 1 {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.productName).fixedSize(horizontal: false, vertical: true)
                            if let quantity = item.quantityText {
                                Text(quantity).font(.system(.caption2, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.priceText.isEmpty ? "—" : "$" + item.priceText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: priceWidth, alignment: .trailing)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.vertical, 6)
                    .transition(.identity)
                }
            }
            if printed >= lineCount {
                rule
                HStack {
                    Text("ITEMS TOTAL")
                    Spacer(minLength: 4)
                    Text(included.reduce(0) { $0 + (Double($1.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0) }, format: .currency(code: "AUD"))
                }
                .font(.system(.subheadline, design: .monospaced).bold())
                .padding(.top, 14)
                .padding(.bottom, 6)
                if let total = result?.totalAmount {
                    Text("Original receipt: \(total, format: .currency(code: "AUD"))")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.bottom, 12)
                }
                Text(included.isEmpty ? "No items selected · Edit to add them back" : "\(included.count) items selected")
                    .font(.system(.caption2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 22)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(width: width, alignment: .top)
        .foregroundStyle(ink)
        .background(paper)
        .clipShape(ReceiptPaperEdge(torn: tearing))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: -2)
    }

    private var rule: some View {
        UnevenReceiptRule()
            .stroke(ink.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }

    private func printer(width: CGFloat, paperWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(.black.opacity(0.8))
                .frame(width: paperWidth + 16, height: 12)
                .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 1) }
                .padding(.top, 4)
            HStack(spacing: 7) {
                Circle().fill(isReady ? Color.green : Color.orange).frame(width: 5, height: 5)
                    .shadow(color: (isReady ? Color.green : Color.orange).opacity(0.5), radius: 4)
                Text(isSaving || tearing ? "" : isReady ? "Ready" : "Processing")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                ForEach(0..<5) { _ in
                    Capsule().fill(.black.opacity(0.35)).frame(width: 2, height: 12)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [Color(white: 0.29), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
        }
    }

}

/// Actual cut paper silhouette, rather than a printed dashed rule.
private struct ReceiptPaperEdge: Shape {
    var torn: Bool
    func path(in rect: CGRect) -> Path {
        let teeth = max(1, Int(rect.width / 9))
        let step = rect.width / CGFloat(teeth)
        let depth: CGFloat = 4
        return Path { path in
            path.move(to: CGPoint(x: 0, y: depth))
            for tooth in 0..<teeth {
                let x = CGFloat(tooth) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: 0))
                path.addLine(to: CGPoint(x: x + step, y: depth))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - (torn ? depth : 0)))
            for tooth in (0..<teeth).reversed() {
                let x = CGFloat(tooth) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.height))
                path.addLine(to: CGPoint(x: x, y: rect.height - (torn ? depth : 0)))
            }
            path.closeSubpath()
        }
    }
}

private struct UnevenReceiptRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
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
