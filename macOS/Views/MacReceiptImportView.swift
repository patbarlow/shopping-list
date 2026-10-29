import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import Vision

struct MacReceiptImportView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var busy = false
    @State private var status = "Reading receipt…"
    @State private var result: ReceiptScanResponse?
    @State private var items: [EditableReceiptItem] = []
    @State private var error: String?
    private var valid: Bool {
        let included = items.filter(\.isIncluded)
        return !included.isEmpty && included.allSatisfy {
            !$0.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (Double($0.priceText.replacingOccurrences(of: ",", with: ".")).map { $0.isFinite && $0 >= 0 } ?? false)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(result == nil ? "Import receipt" : "Review your receipt")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy {
                ProgressView(status).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                HStack {
                    Text(result.storeName ?? "Receipt").font(.headline)
                    Text(result.receiptDate ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text(MacStyle.money(result.totalAmount)).font(.headline)
                }
                Text("Review names and line totals before saving. Uncheck anything you don’t want to include.")
                    .foregroundStyle(.secondary)
                List($items) { $item in
                    HStack(spacing: 12) {
                        Toggle("Include", isOn: $item.isIncluded).labelsHidden()
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Product name", text: $item.productName)
                                .onChange(of: item.productName) { _, _ in
                                    // A renamed line must not silently retain the old product link.
                                    item.productId = nil; item.purchaseHistoryId = nil; item.isNew = true
                                }
                            Text(item.description).font(.caption).foregroundStyle(.secondary)
                        }
                        if let quantity = item.quantity { Text("×\(quantity.formatted())").foregroundStyle(.secondary) }
                        TextField("Total", text: $item.priceText).frame(width: 80)
                    }.padding(.vertical, 5)
                }
                HStack {
                    Button("Choose another receipt…") { importing = true }
                    Spacer()
                    Button("Save \(items.filter(\.isIncluded).count) items", action: save)
                        .buttonStyle(MacButtonStyle(.primary)).disabled(!valid)
                }
            } else {
                MacEmptyState(title: "Make your receipts useful.", message: "Choose a receipt image or PDF from your Mac. Review the products before adding them to your household’s price history.")
                Button { importing = true } label: { Label("Choose receipt…", hugeIcon: "folder") }
                    .buttonStyle(MacButtonStyle(.primary)).frame(maxWidth: .infinity).padding(.bottom, 24)
            }
        }.padding(24).frame(width: 660, height: 580)
            .interactiveDismissDisabled(busy)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf]) { response in
                switch response {
                case .success(let url): scan(url)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !busy else { return false }; scan(url); return true
            }
    }
    private func scan(_ url: URL) {
        guard !busy else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let isPDF = url.pathExtension.lowercased() == "pdf"
            busy = true; error = nil; status = "Reading receipt…"
            Task {
                defer { busy = false }
                do {
                    let scan: ReceiptScanResponse
                    if isPDF {
                        // Preserve all PDF pages rather than sending only the first page as a photo.
                        let text = try await MacReceiptPDF.text(from: data)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            error = "This PDF has no readable text. Export the receipt as an image and import that instead."; return
                        }
                        scan = try await services.api.scanReceipt(householdId: householdId, receiptText: text)
                    } else {
                        let image = try await MacImageImport.jpeg(data)
                        scan = try await services.api.scanReceipt(householdId: householdId, imageBase64: image.base64EncodedString())
                    }
                    result = scan; items = scan.items.map(EditableReceiptItem.init)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard let result, valid, !busy else { return }
        busy = true; error = nil; status = "Saving receipt…"
        let payload: [[String: Any]] = items.filter(\.isIncluded).map { item in
            var value: [String: Any] = ["receipt_description": item.description]
            if let id = item.productId { value["product_id"] = id }
            else { value["new_product_name"] = item.productName }
            value["purchase_history_id"] = item.purchaseHistoryId
            value["quantity"] = item.quantity
            let price = Double(item.priceText.replacingOccurrences(of: ",", with: "."))
            value["price_paid"] = price
            value["unit_price"] = price.map { $0 / max(item.quantity ?? 1, 0.001) }
            value["size_value"] = item.sizeValue
            value["size_unit"] = item.sizeUnit
            return value
        }
        Task {
            do {
                try await services.api.confirmReceipt(householdId: householdId, storeName: result.storeName, totalAmount: result.totalAmount, receiptDate: result.receiptDate, items: payload)
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Text PDFs retain their text; scanned PDFs are read page by page on a worker.
private enum MacReceiptPDF {
    static func text(from data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(text); continue
                }
                guard let pdf = page.pageRef else { continue }
                let bounds = pdf.getBoxRect(.mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let scale = 2000 / max(bounds.width, bounds.height)
                let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.concatenate(pdf.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pdf)
                guard let image = context.makeImage() else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
            return pages.joined(separator: "\n\n")
        }.value
    }
}
