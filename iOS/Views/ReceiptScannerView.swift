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
    /// is ever presented, so it can open straight into printing instead of
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

    /// Where the scan is reading from, kept so a failed stream can be retried
    /// through the one-shot endpoint with the same input.
    private enum ScanSource {
        case text(String)
        case image(String) // base64 JPEG

        var requestBody: [String: Any] {
            switch self {
            case .text(let text):    return ["receipt_text": text]
            case .image(let base64): return ["image_base64": base64, "media_type": "image/jpeg"]
            }
        }
    }

    @State private var stage: ReceiptPrintingView.Stage = .printing
    @State private var failureMessage: String? = nil
    @State private var printer = ReceiptPrinter()
    @State private var scanResult: ReceiptScanResponse? = nil
    @State private var editableItems: [EditableReceiptItem] = []
    @State private var showEditSheet = false

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
                if let failureMessage {
                    failedView(failureMessage)
                } else {
                    ReceiptPrintingView(
                        printer: printer,
                        stage: stage,
                        includedCount: includedCount,
                        includedTotal: includedTotal,
                        onEdit: { showEditSheet = true },
                        onTearOff: { confirmReceipt() }
                    )
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(stage == .saving)
                }
            }
        }
        // Saving is the one point where backing out would leave the receipt
        // half-imported, so the sheet holds still until it lands.
        .interactiveDismissDisabled(stage == .saving)
        .sheet(isPresented: $showEditSheet) {
            ReceiptEditSheet(
                items: $editableItems,
                storeName: scanResult?.storeName,
                receiptTotal: scanResult?.totalAmount,
                printedItemCount: scanResult?.itemCount,
                needsReview: scanResult?.needsReview == true,
                householdId: householdId
            )
        }
        // However the sheet was closed, the paper reprints with what changed.
        .onChange(of: showEditSheet) { _, isShowing in
            if !isShowing { printer.sync(with: editableItems) }
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

    private var navTitle: String {
        if failureMessage != nil { return "Couldn't Read Receipt" }
        return printer.storeName ?? "Receipt"
    }

    private var includedCount: Int { editableItems.filter(\.isIncluded).count }

    private var includedTotal: Double? {
        let included = editableItems.filter(\.isIncluded)
        guard !included.isEmpty else { return nil }
        return included.reduce(0) { $0 + (Double($1.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0) }
    }

    // MARK: - Failure

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Image handling

    private func handlePDF(_ pdfData: Data) async {
        // 1. Prefer the PDF's text layer — most accurate for digital eReceipts.
        //    If extraction is garbled or the server can't parse it, fall through
        //    to image OCR.
        if let text = extractReceiptText(pdfData), await scan(.text(text)) {
            return
        }

        // 2. Fall back to rasterising the PDF and reading it as an image.
        guard let image = renderPDFToImage(pdfData) else {
            fail("Couldn't read that PDF.")
            return
        }
        await scanImage(image)
    }

    private func handlePhotoData(_ data: Data) async {
        guard let image = UIImage(data: data) else {
            fail("Couldn't load that photo.")
            return
        }
        await scanImage(image)
    }

    /// The document scanner can return more than one page (a long receipt
    /// scanned in sections) — stitch them into one tall image, same as the
    /// multi-page PDF path above.
    private func handleScannedPages(_ images: [UIImage]) async {
        guard let stitched = images.count > 1 ? stitchVertically(images) : images.first else {
            fail("Couldn't read that scan.")
            return
        }
        await scanImage(stitched)
    }

    private func scanImage(_ image: UIImage) async {
        guard let compressed = image.compressedForUpload() else {
            fail("Image error.")
            return
        }
        _ = await scan(.image(compressed.base64EncodedString()))
    }

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
            // Receipts flag lines with symbols that aren't Unicode punctuation
            // ("^" promotional, "*"), so count those as readable too.
            .union(CharacterSet(charactersIn: "$€£¢^*+×"))
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

    // MARK: - Scanning

    /// Read the receipt, printing it onto the screen as it arrives.
    ///
    /// The streaming endpoint delivers the store header, then a line per product
    /// as the model reads it, then the checked lines, then the matched result.
    /// If the stream can't be opened or dies mid-receipt we fall back to the
    /// one-shot scan and print its result instead — the paper looks the same
    /// either way, it just fills in at the end.
    ///
    /// Returns false if the receipt couldn't be read at all, so the PDF path can
    /// try again as an image.
    @discardableResult
    private func scan(_ source: ScanSource) async -> Bool {
        // Fresh paper: a retry (a PDF's text layer failing, then its image) must
        // not print onto whatever the previous attempt left behind.
        printer = ReceiptPrinter()
        stage = .printing
        failureMessage = nil

        do {
            var matched: ReceiptScanResponse?
            let events = services.api.scanReceiptStream(householdId: householdId, body: source.requestBody)
            for try await event in events {
                switch event {
                case .store(let name, let date):     printer.setStore(name: name, date: date)
                case .item(let line):                printer.print(line)
                case .totals(let amount, _):         printer.setTotal(amount)
                case .revised(let lines, _):         printer.revise(with: lines)
                case .matched(let result):           matched = result
                case .failed(let error):             throw APIError.serverError(error)
                }
            }
            guard let matched else { throw APIError.serverError(Self.unreadable) }
            await present(matched)
            return true
        } catch let error as APIError where error == .serverError(Self.unreadable) {
            // The receipt was read end to end and there was nothing in it —
            // running the same input through the one-shot scan would only pay
            // for the same answer twice.
            fail("Couldn't find any items on that receipt.")
            return false
        } catch {
            return await scanWithoutStreaming(source)
        }
    }

    /// The server's "I read it and found no items" error, as opposed to a
    /// transport failure worth retrying.
    private static let unreadable = "could_not_parse"

    /// The pre-streaming path, kept as the fallback. Whatever printed before the
    /// stream failed is discarded and reprinted from the finished result, so the
    /// paper can't end up showing a half-read receipt.
    private func scanWithoutStreaming(_ source: ScanSource) async -> Bool {
        do {
            let result: ReceiptScanResponse
            switch source {
            case .text(let text):
                result = try await services.api.scanReceipt(householdId: householdId, receiptText: text)
            case .image(let base64):
                result = try await services.api.scanReceipt(householdId: householdId, imageBase64: base64)
            }
            printer = ReceiptPrinter()
            printer.setStore(name: result.storeName, date: result.receiptDate)
            printer.setTotal(result.totalAmount)
            for item in result.items {
                printer.print(ReceiptPrintedLine(
                    description: item.description,
                    quantity: item.quantity,
                    unitPrice: item.unitPrice,
                    totalPrice: item.totalPrice
                ))
            }
            await present(result)
            return true
        } catch {
            // Both paths failed: this error is the informative one, since a 422
            // here means the receipt genuinely couldn't be read.
            fail("Couldn't read that receipt. (\(error.localizedDescription))")
            return false
        }
    }

    /// Let the paper finish printing, then show what each line will be saved as
    /// and leave the receipt sitting there to be read, edited, or torn off.
    private func present(_ result: ReceiptScanResponse) async {
        scanResult = result
        editableItems = result.items.map { EditableReceiptItem(from: $0) }
        await printer.finish()
        printer.sync(with: editableItems)
        stage = .printed
    }

    private func fail(_ message: String) {
        failureMessage = message
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

    // MARK: - Confirm

    /// Tearing the receipt off is what saves it.
    private func confirmReceipt() {
        guard stage == .printed, let result = scanResult else { return }
        stage = .saving

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
                // The paper is already gone, so there's nothing to go back to.
                fail("Couldn't save that receipt. (\(error.localizedDescription))")
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
