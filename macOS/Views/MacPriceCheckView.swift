import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// File decoding runs away from the UI. The API receives a bounded JPEG,
/// regardless of whether the source was a PNG screenshot or an HEIC photo.
enum MacImageImport {
    static func jpeg(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1800
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return output as Data
        }.value
    }
}

@Observable final class MacPriceDraft {
    var text = ""
    var image: Data?
    var offer: PriceOffer?
    var products: [ProductInsight] = []
    var selectedProduct = ""
    var purchases: [ProductPurchase] = []
    var busy = false
    var error: String?
}

struct MacPriceCheckView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Bindable var draft: MacPriceDraft
    @State private var importing = false
    @State private var importingImage = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if let error = draft.error { MacErrorBanner(message: error) }
            if let offer = draft.offer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(offer.name).font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("\(MacStyle.money(offer.price))\(offer.packSizeLabel.map { " · \($0)" } ?? "")").font(.title2.monospacedDigit())
                            if let baseline = offer.baseline { Text("\(MacStyle.money(baseline.value)) / \(baseline.unit)").foregroundStyle(.secondary) }
                            if let question = offer.question { Text(question).padding(.top, 6) }
                        }.macCard()
                        if offer.baseline != nil {
                            comparison(offer)
                        }
                    }.padding(24).frame(maxWidth: 780).frame(maxWidth: .infinity)
                }
            } else {
                MacEmptyState(title: "Good price? Let’s find out.", message: "Drop in a product photo, paste a screenshot or type the price and pack size. Compare it with your household’s receipts.")
            }
            if draft.busy { ProgressView("Checking the price…").padding() }
            composer.padding(20).frame(maxWidth: 840).frame(maxWidth: .infinity)
        }
        .navigationTitle("Price check")
        .safeAreaInset(edge: .top, alignment: .trailing) {
            Button("New check") { draft.offer = nil; draft.text = ""; draft.image = nil; draft.error = nil; draft.selectedProduct = ""; draft.purchases = [] }
                .disabled(draft.busy).padding(.trailing, 24).padding(.vertical, 8)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): loadFile(url)
            case .failure(let error): draft.error = error.localizedDescription
            }
        }
        .onPasteCommand(of: [.image]) { _ in pasteImage() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !draft.busy else { return false }; loadFile(url); return true
        }
        .task(id: comparisonIdentity) {
            draft.purchases = []
            guard !draft.selectedProduct.isEmpty else { return }
            do {
                let result = try await services.api.fetchProductInsight(householdId: householdId, productId: draft.selectedProduct)
                if !Task.isCancelled { draft.purchases = draft.offer?.matchingPurchases(result.purchases, productId: draft.selectedProduct) ?? [] }
            } catch { if !Task.isCancelled { draft.error = error.localizedDescription } }
        }
    }

    private var comparisonIdentity: String {
        [draft.selectedProduct, draft.offer?.name ?? "",
         draft.offer?.historyMatches?.flatMap(\.purchaseIds).sorted().joined(separator: ",") ?? "legacy"]
            .joined(separator: "|")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = draft.image, let image = NSImage(data: data) {
                HStack {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Photo attached").foregroundStyle(.secondary)
                    Button { draft.image = nil } label: { Image(hugeIcon: "xmark") }.buttonStyle(MacButtonStyle(.subtle, compact: true)).help("Remove photo")
                }
            }
            TextField("e.g. Greek yoghurt, 1 kg for $6.50", text: $draft.text)
                .textFieldStyle(.plain).font(.body).focused($focused).onSubmit(send)
            HStack {
                Button { importing = true } label: { Label("Choose image…", hugeIcon: "photo") }
                Button("Paste image") { pasteImage() }.help("Paste a copied screenshot or photo")
                Spacer()
                if importingImage { ProgressView().controlSize(.small) }
                Button("Check price", action: send).buttonStyle(MacButtonStyle(.primary)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.busy || importingImage || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.image == nil))
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .disabled(draft.busy)
    }

    private func comparison(_ offer: PriceOffer) -> some View {
        let value = PriceComparison(offer: offer, purchases: draft.purchases)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Compare with your purchases").font(.system(.headline, design: .rounded))
            Picker("Product", selection: $draft.selectedProduct) {
                Text("Choose a matching product…").tag("")
                ForEach(draft.products) { Text($0.name).tag($0.id) }
            }
            if draft.selectedProduct.isEmpty {
                Text(draft.products.isEmpty ? "No receipt prices yet. Import a receipt to build your price history." : "Choose the same product and variant for a fair comparison.").foregroundStyle(.secondary)
            } else if let change = value.changeFromAverage {
                Text(abs(change) < 1 ? "About your usual price." : "\(abs(change).formatted(.number.precision(.fractionLength(0))))% \(change < 0 ? "below" : "above") your average.")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                if let average = value.average, let pack = value.priceForOfferPack(average) {
                    Text("Your average works out to \(MacStyle.money(pack)) for this pack size, across \(value.comparable.count) purchases.").foregroundStyle(.secondary)
                }
                ForEach(Array(value.comparable.prefix(5))) { purchase in
                    HStack {
                        VStack(alignment: .leading) { Text(purchase.variant ?? offer.name); Text(purchase.storeName ?? "Purchase").font(.caption).foregroundStyle(.secondary) }
                        Text(MacStyle.date(purchase.purchasedAt)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MacStyle.money(purchase.unitPrice)) / \(purchase.unitPriceUnit ?? "")")
                    }
                }
            } else {
                Text("No comparable pack sizes in your receipt history for this product.").foregroundStyle(.secondary)
            }
        }.macCard()
    }

    private func send() {
        guard !draft.busy, !importingImage, draft.image != nil || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.busy = true; draft.error = nil
        Task {
            defer { draft.busy = false }
            do {
                let offer = try await services.api.readPriceOffer(householdId: householdId, text: draft.text.isEmpty ? "Is this a good price?" : draft.text, image: draft.image, previous: draft.image == nil ? draft.offer : nil)
                draft.offer = offer
                draft.products = try await services.api.fetchProductInsights(householdId: householdId)
                draft.selectedProduct = offer.historyMatches?.count == 1 ? (offer.historyMatches?.first?.productId ?? "") : (offer.historyMatches == nil ? PriceProductMatcher.exactMatch(name: offer.name, products: draft.products)?.id ?? "" : "")
                draft.text = ""; draft.image = nil
                focused = true
            } catch { draft.error = error.localizedDescription }
        }
    }
    private func pasteImage() {
        if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) {
            attach(data)
        } else { draft.error = "Copy an image or screenshot first, then choose Paste image." }
    }
    private func loadFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do { attach(try Data(contentsOf: url)) }
        catch { draft.error = error.localizedDescription }
    }
    private func attach(_ data: Data) {
        importingImage = true; draft.error = nil
        Task {
            defer { importingImage = false }
            do { draft.image = try await MacImageImport.jpeg(data); focused = true }
            catch { draft.error = "This image couldn’t be opened. Try a JPEG, PNG or HEIC photo." }
        }
    }
}
