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
        /// The receipt is printing onto the screen — this covers the whole scan,
        /// from "paper feeding" through each line arriving to the total.
        case printing
        case review
        case confirming
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

    @State private var phase: Phase = .printing
    @State private var printer = ReceiptPrinter()
    @State private var scanResult: ReceiptScanResponse? = nil
    @State private var editableItems: [EditableReceiptItem] = []
    @State private var errorMessage: String? = nil

    // Product picker sheet state
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
                case .failed:     failedView
                case .printing:   ReceiptPrintingView(printer: printer)
                case .review:     reviewView
                case .confirming: loadingView("Saving…")
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
        .sheet(isPresented: $showProductPicker) {
            ProductPickerSheet(householdId: householdId, initialQuery: productPickerQuery) { result in
                applyPickerResult(result)
                showProductPicker = false
            }
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
        switch phase {
        case .failed:     return "Couldn't Read Receipt"
        case .printing:   return printer.storeName ?? "Reading Receipt…"
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

    // MARK: - Loading

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private var includedCount: Int { editableItems.filter(\.isIncluded).count }

    /// Units, not rows — a "×2" line counts twice, the way a receipt's own
    /// "8 Items" footer counts. A weighed line is one item whatever it weighs.
    private var scannedUnitCount: Int {
        editableItems.reduce(0) { total, item in
            guard let q = item.quantity, q > 0, q == q.rounded() else { return total + 1 }
            return total + Int(q)
        }
    }
    private var newCount: Int { editableItems.filter { $0.isIncluded && $0.productId == nil }.count }

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
                    if let printed = result.itemCount, printed != scannedUnitCount {
                        LabeledContent("Items on receipt", value: "\(printed)")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    if result.needsReview == true {
                        Label("This receipt's numbers didn't add up. Check the quantities before saving — tap one to change it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                ForEach($editableItems) { $item in
                    itemRow(item: $item)
                }
            } header: {
                Text("^[\(includedCount) item](inflect: true)")
            } footer: {
                Text(newCount > 0
                     ? "Tap a name to change the match. \(newCount) will be added as new products."
                     : "Tap a name to link it to a different product.")
            }
        }
    }

    /// When the receipt's own numbers didn't reconcile, every row gets its
    /// quantity control so a miscounted multi-buy can be moved to the right line.
    private var showsAllQuantityControls: Bool { scanResult?.needsReview == true }

    @ViewBuilder
    private func itemRow(item: Binding<EditableReceiptItem>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: item.isIncluded).labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.wrappedValue.productId == nil {
                        // New product: name is editable inline.
                        TextField("Product name", text: item.productName)
                            .font(.body.bold())
                            .textInputAutocapitalization(.words)
                        Text("NEW")
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    } else {
                        // Linked to an existing product.
                        Text(item.wrappedValue.productName)
                            .font(.body.bold())
                            .foregroundStyle(.primary)
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }

                    // Search / relink to a different (or existing) product.
                    Button {
                        pickingForItemId = item.wrappedValue.id
                        productPickerQuery = item.wrappedValue.productName
                        showProductPicker = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 4) {
                    quantityControl(item: item)
                    Text(item.wrappedValue.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if item.wrappedValue.needsReview {
                    Label("Quantity didn't match the printed price — check this line.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField("0.00", text: item.priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
        }
        .opacity(item.wrappedValue.isIncluded ? 1 : 0.4)
    }


    /// The detected quantity, shown with the unit price it multiplies out from
    /// ("×2 @ $1.69") so a multi-buy stapled onto the wrong product is visible
    /// against the line's price. Unit counts are tappable to correct.
    @ViewBuilder
    private func quantityControl(item: Binding<EditableReceiptItem>) -> some View {
        if item.wrappedValue.isUnitCount,
           item.wrappedValue.quantityDetail != nil || item.wrappedValue.needsReview || showsAllQuantityControls {
            Menu {
                ForEach(1...9, id: \.self) { n in
                    Button("×\(n)") { setQuantity(Double(n), on: item) }
                }
            } label: {
                Text(item.wrappedValue.quantityDetail ?? "×1")
                    .font(.caption)
                    .foregroundStyle(item.wrappedValue.needsReview ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
        } else if let detail = item.wrappedValue.quantityDetail {
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A corrected count re-derives the unit price from what was paid, so the
    /// $/100g baseline the server computes stays consistent with the line.
    private func setQuantity(_ quantity: Double, on item: Binding<EditableReceiptItem>) {
        item.wrappedValue.quantity = quantity
        let paid = Double(item.wrappedValue.priceText.replacingOccurrences(of: ",", with: "."))
        item.wrappedValue.unitPrice = paid.map { $0 / quantity }
        item.wrappedValue.needsReview = false
    }

    // MARK: - Picker result

    private func applyPickerResult(_ result: ProductPickerResult) {
        guard let itemId = pickingForItemId,
              let idx = editableItems.firstIndex(where: { $0.id == itemId }) else {
            pickingForItemId = nil
            return
        }
        switch result {
        case .existing(let id, let name):
            editableItems[idx].productId = id
            editableItems[idx].productName = name
            editableItems[idx].isNew = false
        case .create(let name):
            editableItems[idx].productId = nil
            editableItems[idx].productName = name
            editableItems[idx].isNew = true
        }
        // A manual choice no longer maps to the auto-detected list entry.
        editableItems[idx].purchaseHistoryId = nil
        editableItems[idx].isIncluded = true
        pickingForItemId = nil
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
        phase = .printing
        errorMessage = nil

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

    /// Let the paper finish printing, then hand off to matching.
    private func present(_ result: ReceiptScanResponse) async {
        scanResult = result
        editableItems = result.items.map { EditableReceiptItem(from: $0) }
        await printer.finish()
        phase = .review
    }

    private func fail(_ message: String) {
        phase = .failed
        errorMessage = message
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

// MARK: - Receipt printing

/// A torn-off strip of receipt paper: zigzag along the top and bottom edges,
/// the way a thermal printer's cutter leaves it.
private struct TornEdge: Shape {
    var tooth: CGFloat = 9
    var depth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Teeth are sized off the width alone, so they stay put while the paper
        // grows — deriving them from the height would make them crawl.
        let count = max(2, Int((rect.width / tooth).rounded()))
        let step = rect.width / CGFloat(count)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        for i in 0 ..< count {
            let x = rect.minX + CGFloat(i) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY + depth))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        for i in 0 ..< count {
            let x = rect.maxX - CGFloat(i) * step
            path.addLine(to: CGPoint(x: x - step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x - step, y: rect.maxY - depth))
        }
        path.closeSubpath()
        return path
    }
}

/// The scan, printing. The paper feeds up from the bottom of the screen and each
/// product lands on it as the scan reads it — the store header first, then a line
/// per item, then the total. Same monospaced, dashed-rule language as
/// TripReceiptView, so a receipt being read and a receipt already saved look
/// like the same object.
private struct ReceiptPrintingView: View {
    let printer: ReceiptPrinter

    private let paperWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            // Anchored to the bottom, so the paper grows upward out of the slot:
            // each new line lands at the bottom edge and pushes the rest up, and
            // once the receipt is taller than the screen the top scrolls away.
            ScrollView {
                paper
                    .frame(maxWidth: paperWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .safeAreaPadding(.bottom, 8)

            printerSlot
        }
        // Printer chatter: one tick as each line lands.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.4), trigger: printer.lines.count)
        .animation(.spring(duration: 0.32), value: printer.lines.count)
        .animation(.spring(duration: 0.32), value: printer.totalPrinted)
        .animation(.easeInOut(duration: 0.25), value: printer.storeName)
    }

    /// The lip the paper feeds out of, pinned to the bottom edge.
    private var printerSlot: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 54, height: 4)
            .padding(.bottom, 6)
            .allowsHitTesting(false)
    }

    private var paper: some View {
        VStack(spacing: 0) {
            header
            if !printer.lines.isEmpty {
                dashedDivider
                lineItems
            }
            if printer.totalPrinted {
                dashedDivider
                total
            }
        }
        .background {
            Color(.secondarySystemGroupedBackground)
                .clipShape(TornEdge())
                .shadow(color: .black.opacity(0.12), radius: 14, y: -2)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            if let store = printer.storeName {
                Text(store)
                    .font(.system(.headline, design: .monospaced).weight(.bold))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                if let date = printer.dateText {
                    Text(date)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            } else {
                // Before the first record arrives there's nothing to print yet,
                // so the paper feeds blank rather than faking progress.
                Text("Reading the receipt…")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
    }

    private var lineItems: some View {
        VStack(spacing: 0) {
            ForEach(Array(printer.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.description)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let qty = line.quantityText, let unit = line.unitPrice {
                            Text(String(format: "  %@ @ $%.2f", qty, unit))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let price = line.totalPrice {
                        Text(price, format: .currency(code: "AUD"))
                            .font(.system(.footnote, design: .monospaced))
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
                // Each line arrives at the bottom edge, as if fed out of the slot.
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, 16)
    }

    private var total: some View {
        HStack {
            Text("TOTAL").font(.system(.subheadline, design: .monospaced).weight(.bold))
            Spacer()
            if let amount = printer.totalAmount {
                Text(amount, format: .currency(code: "AUD"))
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 26)
        .transition(.opacity)
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
