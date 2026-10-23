import SwiftUI
import PhotosUI
import Photos
import AVFoundation

struct PriceCheckView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var speech = SpeechService()
    @State private var text = ""
    @State private var attachment: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var busy = false
    @State private var error: String?
    @State private var offer: PriceOffer?
    @State private var products: [ProductInsight] = []
    @State private var search = ""
    @State private var comparison: PriceComparison?
    @State private var selected: ProductInsight?
    @State private var recentImage: UIImage?
    @State private var recentID: String?
    @State private var dismissedRecentID: String?
    @State private var messages: [Message] = []
    @AppStorage("priceCheckRecentPhotos") private var recentEnabled = false
    @FocusState private var focused: Bool

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let image: UIImage?
        var isUser = true
    }

    private var candidates: [ProductInsight] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return Array(products.prefix(12)) }
        return Array(products.filter { p in terms.allSatisfy { p.name.localizedCaseInsensitiveContains($0) } }.prefix(20))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty { introduction }
                    ForEach(messages) { message in
                        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
                            if let image = message.image {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            if !message.text.isEmpty { Text(message.text).padding(14).background(message.isUser ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20)) }
                        }.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                    }
                    if busy { ProgressView("Checking…").frame(maxWidth: .infinity) }
                    if let offer { offerCard(offer) }
                    if let comparison, let selected { comparisonCard(comparison, product: selected).id("comparison") }
                    if offer != nil && !busy { productPicker }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selected?.id) { _, id in
                if id != nil { withAnimation { proxy.scrollTo("comparison", anchor: .top) } }
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Check price")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New comparison", systemImage: "square.and.pencil") {
                        messages = []; offer = nil; comparison = nil; selected = nil; attachment = nil; text = ""; error = nil
                    }.disabled(busy)
                    Button(recentEnabled ? "Turn off recent photos" : "Enable recent photo suggestion", systemImage: "photo.badge.clock") {
                        if recentEnabled { recentEnabled = false; recentImage = nil }
                        else { Task { await enableRecent() } }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .sheet(isPresented: $showCamera) {
            PriceCheckCamera { image in attachment = image; showCamera = false }
                .ignoresSafeArea()
        }
        .onChange(of: photo) { _, item in
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    attachment = image
                } catch { self.error = "Couldn't load that photo. Try choosing it again." }
                photo = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadRecent() } }
            else { speech.stop(flush: true) }
        }
        .task {
            speech.onUtterance = { phrase in text += (text.isEmpty ? "" : " ") + phrase }
            await loadRecent()
        }
        .onDisappear { speech.stop(flush: true) }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "tag").font(.system(size: 36)).foregroundStyle(.tint)
            Text("Worth picking up?").font(.largeTitle.bold())
            Text("Show me a price. I'll compare it with what you've paid before, using the same pack size or unit price.")
                .foregroundStyle(.secondary)
            Button { text = "Is Red Bull 4 × 250mL for $9.83 a good price?"; focused = true } label: {
                Label("Is this Red Bull a good price?", systemImage: "bubble.left")
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
            }
            if !recentEnabled {
                Button("Enable recent photo suggestion") { Task { await enableRecent() } }
                    .font(.footnote)
            }
        }.padding(.vertical, 16)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recentImage, attachment == nil, recentID != dismissedRecentID {
                HStack {
                    Button {
                        attachment = recentImage; dismissedRecentID = recentID
                    } label: {
                        HStack {
                            Image(uiImage: recentImage).resizable().scaledToFill().frame(width: 34, height: 34).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                            Text("Attach recent photo").font(.subheadline)
                        }
                    }
                    Spacer()
                    Button { dismissedRecentID = recentID } label: { Image(systemName: "xmark") }.accessibilityLabel("Hide recent photo")
                }
            }
            if let attachment {
                HStack {
                    Image(uiImage: attachment).resizable().scaledToFit().frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Ready to check").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove photo")
                }
            }
            if speech.isRecording { Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript).font(.callout).foregroundStyle(.secondary) }
            if let error = speech.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button("Camera", systemImage: "camera") {
                        speech.stop(flush: true)
                        Task {
                            if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true }
                            else { error = "Allow camera access in Settings, or choose a photo instead." }
                        }
                    }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button("Photos", systemImage: "photo") { showPhotos = true }
                } label: { Image(systemName: "plus").font(.title2).frame(width: 30, height: 36) }
                .accessibilityLabel("Attach photo")
                TextField("Ask about a price…", text: $text, axis: .vertical)
                    .lineLimit(1...4).focused($focused).accessibilityIdentifier("price-check-input")
                    .padding(.vertical, 7)
                Button {
                    if speech.isRecording { speech.stop(flush: true) }
                    else { focused = false; Task { await speech.start() } }
                } label: { Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic").font(.title2).frame(height: 36) }
                    .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate question")
                Button { Task { await check() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }.disabled(busy || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil && speech.transcript.isEmpty))
                    .accessibilityLabel("Check price").accessibilityIdentifier("price-check-send")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .disabled(busy)
    }

    private func offerCard(_ offer: PriceOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.name).font(.headline)
            if let price = offer.price { Text(price, format: .currency(code: "AUD")).font(.largeTitle.bold()) }
            if let packSize = offer.packSizeLabel { Text("\(packSize) total pack size").foregroundStyle(.secondary) }
            if let baseline = offer.baseline { Text("\(money(baseline.value)) / \(baseline.unit)").font(.title3.weight(.semibold)) }
            if let question = offer.question { Text(question).foregroundStyle(.secondary) }
            Text("Read that wrong? Tell me the correct price or pack size below.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func comparisonCard(_ comparison: PriceComparison, product: ProductInsight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let change = comparison.changeFromLast {
                let headline = abs(change) < 1 ? "About the same as last time" : "\(abs(change).formatted(.number.precision(.fractionLength(0))))% \(change > 0 ? "more" : "less") than last time"
                Label(headline, systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.title2.bold()).foregroundStyle(change > 0 ? Color.orange : Color.green)
                if let baseline = comparison.offer.baseline {
                    HStack {
                        metric("This offer", baseline.value, baseline.unit)
                        Spacer()
                        if let average = comparison.average { metric("Your average", average, baseline.unit) }
                    }
                    if let lowest = comparison.lowest { Text("Your lowest: \(money(lowest)) / \(baseline.unit)").font(.subheadline) }
                }
                Text("Based on \(comparison.comparable.count) comparable receipt \(comparison.comparable.count == 1 ? "purchase" : "purchases").").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(comparison.comparable.prefix(3))) { purchase in
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(purchase.variant ?? product.name).font(.subheadline.weight(.medium))
                        Text("\(purchase.storeName ?? "Saved receipt") · \(purchase.dayKey)").font(.caption).foregroundStyle(.secondary)
                        if let value = purchase.unitPrice, let unit = purchase.unitPriceUnit { Text("\(money(value)) / \(unit)").font(.subheadline.monospacedDigit()) }
                    }
                }
            } else {
                Label("Not enough comparable history", systemImage: "questionmark.circle").font(.headline)
                Text("These receipts don't have a usable size in the same units. I won't compare different packs as if they're equal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            NavigationLink("View \(product.name) history") {
                ProductDetailView(householdId: householdId, productId: product.id, fallbackName: product.name)
            }.font(.subheadline)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
    }

    private func metric(_ title: String, _ value: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(money(value)).font(.title3.bold().monospacedDigit())
            Text("/ \(unit)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var productPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected == nil ? "Which product did you buy?" : "Compare another product").font(.headline)
            Text("Check the brand and variant before comparing.").font(.caption).foregroundStyle(.secondary)
            TextField("Search your purchases", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("price-check-product-search")
            if candidates.isEmpty { Text("No matching purchases. Try a shorter name, or import a receipt first.").font(.callout).foregroundStyle(.secondary) }
            ForEach(candidates) { product in
                Button { Task { await compare(product) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(product.name).foregroundStyle(.primary)
                            Text("\(product.timesPurchased) receipt purchases").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected?.id == product.id ? "checkmark.circle.fill" : "chevron.right")
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }
                Divider()
            }
        }
    }

    private func check() async {
        speech.stop(flush: true)
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty || attachment != nil else { return }
        guard question.count <= 2000 else { error = "Please keep your question under 2,000 characters."; return }
        let image = attachment
        let data = image?.compressedForUpload()
        if image != nil && data == nil { error = "Couldn't prepare that photo."; return }
        busy = true; error = nil; focused = false
        defer { busy = false }
        do {
            let result = try await services.api.readPriceOffer(householdId: householdId, text: question, image: data, previous: image == nil ? offer : nil)
            products = try await services.api.fetchProductInsights(householdId: householdId)
            if let comparison, let change = comparison.changeFromLast, let previous = comparison.offer.baseline {
                let summary = "\(comparison.offer.name): \(money(previous.value)) / \(previous.unit), \(abs(change).formatted(.number.precision(.fractionLength(0))))% \(change >= 0 ? "more" : "less") than your last comparable purchase."
                messages.append(Message(text: summary, image: nil, isUser: false))
            }
            messages.append(Message(text: question.isEmpty ? "Is this a good price?" : question, image: data.flatMap(UIImage.init(data:))))
            if messages.count > 12 { messages.removeFirst(messages.count - 12) }
            offer = result; comparison = nil; selected = nil
            search = result.name.split(separator: " ").prefix(2).joined(separator: " ")
            text = ""; attachment = nil
        } catch { self.error = "Couldn't check that price right now. Your question and photo are still here—try again." }
    }

    private func compare(_ product: ProductInsight) async {
        guard let offer, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let detail = try await services.api.fetchProductInsight(householdId: householdId, productId: product.id)
            comparison = PriceComparison(offer: offer, purchases: detail.purchases)
            selected = product
        } catch { self.error = "Couldn't load purchase history. Tap the product to retry." }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "AUD").precision(.fractionLength(2)))
    }

    private func enableRecent() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        recentEnabled = status == .authorized || status == .limited
        if recentEnabled { await loadRecent() }
        else { error = "Photo suggestions need Photos access in Settings. You can still choose a photo with the + button." }
    }

    private func loadRecent() async {
        guard recentEnabled else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { recentImage = nil; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(format: "creationDate > %@", Date().addingTimeInterval(-86400) as NSDate)
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { recentImage = nil; return }
        guard asset.localIdentifier != recentID else { return }
        let request = PHImageRequestOptions()
        request.deliveryMode = .highQualityFormat
        request.isNetworkAccessAllowed = true
        let image: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: request) { image, _ in
                continuation.resume(returning: image)
            }
        }
        recentID = asset.localIdentifier; recentImage = image
    }
}

private struct PriceCheckCamera: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PriceCheckCamera
        init(_ parent: PriceCheckCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
