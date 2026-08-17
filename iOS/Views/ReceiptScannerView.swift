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
        case printing(ReceiptScanResponse)
        case review
        case confirming
    }

    @State private var phase: Phase = .scanning
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
                case .failed:                failedView
                case .scanning:               ScanningProgressView()
                case .printing(let result):   ReceiptPrintingView(result: result) { phase = .review }
                case .review:                 reviewView
                case .confirming:             loadingView("Saving…")
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
                    if let qty = item.wrappedValue.quantityText {
                        Text(qty).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.wrappedValue.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        phase = .printing(result)
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

// MARK: - Receipt printing reveal

/// The scan result already arrived in one response; this plays it onto the
/// screen the way a receipt prints — store, then date, then each line item,
/// then the total — before handing off to item matching. Same visual
/// language as TripReceiptView (monospaced, dashed rules) so a scanned
/// receipt and a saved one look like the same object.
private struct ReceiptPrintingView: View {
    let result: ReceiptScanResponse
    let onFinished: () -> Void

    /// 0 = nothing shown, 1 = store, 2 = + date, 3+i = + item i, then total.
    @State private var revealedLines = 0
    @State private var revealedTotal = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    if revealedLines >= 1 {
                        Text(result.storeName ?? "Receipt")
                            .font(.system(.headline, design: .monospaced).weight(.bold))
                            .multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if revealedLines >= 2, let date = displayDate {
                        Text(date)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 14)
                .padding(.horizontal, 16)
                .frame(minHeight: 66)

                dashedDivider

                VStack(spacing: 0) {
                    ForEach(Array(result.items.enumerated()), id: \.offset) { i, item in
                        if revealedLines >= 3 + i {
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.description)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let price = item.totalPrice {
                                    Text(price, format: .currency(code: "AUD"))
                                        .font(.system(.footnote, design: .monospaced))
                                }
                            }
                            .padding(.vertical, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.horizontal, 16)

                if revealedTotal {
                    dashedDivider
                    HStack {
                        Text("TOTAL").font(.system(.subheadline, design: .monospaced).weight(.bold))
                        Spacer()
                        if let total = result.totalAmount {
                            Text(total, format: .currency(code: "AUD"))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
                    .transition(.opacity)
                }
            }
            // Without this, the card sizes to fit its content — and early in
            // the reveal (before any item rows exist) the only thing wide
            // enough to establish a width is the dashed divider's fixed run
            // of characters, which falls short of the screen on most
            // devices. That's what showed as the card — and the grey behind
            // it — not reaching the edges for the first moment of the reveal.
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .task { await runReveal() }
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

    private var displayDate: String? {
        guard let raw = result.receiptDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(raw.prefix(10))) else { return nil }
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: d)
    }

    private func runReveal() async {
        func pause(_ delay: Duration) async { try? await Task.sleep(for: delay) }

        await pause(.milliseconds(300))
        withAnimation(.spring(duration: 0.35)) { revealedLines = 1 }
        await pause(.milliseconds(350))
        withAnimation(.spring(duration: 0.35)) { revealedLines = 2 }
        await pause(.milliseconds(300))
        for i in 0 ..< result.items.count {
            withAnimation(.spring(duration: 0.3)) { revealedLines = 3 + i }
            await pause(.milliseconds(90))
        }
        await pause(.milliseconds(250))
        withAnimation(.spring(duration: 0.35)) { revealedTotal = true }
        await pause(.milliseconds(700))
        onFinished()
    }
}

// MARK: - Scanning progress

/// Animated, staged indicator shown while a receipt is being read & matched.
/// The stages mirror the real pipeline; they advance on a timer since the work
/// happens in a single server round-trip.
private struct ScanningProgressView: View {
    private struct Stage { let icon: String; let label: String }
    private let stages: [Stage] = [
        Stage(icon: "doc.text.viewfinder", label: "Reading the receipt…"),
        Stage(icon: "list.bullet.rectangle", label: "Pulling out the items…"),
        Stage(icon: "wand.and.stars", label: "Matching to your products…"),
        Stage(icon: "sparkles", label: "Tidying up the names…"),
    ]
    @State private var index = 0

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: stages[index].icon)
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Text(stages[index].label)
                .font(.headline)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: index)

            HStack(spacing: 6) {
                ForEach(stages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == index ? 18 : 6, height: 6)
                        .animation(.spring(duration: 0.3), value: index)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Advance through the stages, easing off near the end so we don't claim
            // completion before the response actually arrives.
            while !Task.isCancelled {
                let delay: Duration = index >= stages.count - 2 ? .milliseconds(1800) : .milliseconds(1100)
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                if index < stages.count - 1 { withAnimation { index += 1 } }
                else { return }
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
