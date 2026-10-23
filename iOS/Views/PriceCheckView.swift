import SwiftUI
import PhotosUI
import Photos
import AVFoundation

struct PriceCheckView: View {
    let householdId: String
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var speech = SpeechService()
    @State private var text = ""
    @State private var attachment: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showProducts = false
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
        var comparison: PriceComparison?
        var product: ProductInsight?
    }

    private var candidates: [ProductInsight] {
        let terms = (offer?.name ?? "").lowercased().split(separator: " ").prefix(2).map(String.init)
        return matchingProducts(terms)
    }

    private var searchResults: [ProductInsight] {
        matchingProducts(search.lowercased().split(separator: " ").map(String.init))
    }

    private func matchingProducts(_ terms: [String]) -> [ProductInsight] {
        products.filter { p in terms.allSatisfy { p.name.localizedCaseInsensitiveContains($0) } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if messages.isEmpty { introduction }
                    ForEach(messages) { message in
                        if message.isUser {
                            userMessage(message)
                        } else if let result = message.comparison, let product = message.product {
                            PriceCheckReply(comparison: result, product: product)
                        } else {
                            Text(message.text).font(.body).lineSpacing(5)
                        }
                    }
                    if busy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Checking your prices…").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                    } else if let comparison, let selected {
                        PriceCheckReply(comparison: comparison, product: selected) { search = ""; showProducts = true }
                            .id("reply")
                    } else if let offer {
                        pendingReply(offer).id("reply")
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: busy) { _, value in
                if !value {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("reply", anchor: .top) }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Price check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New chat", systemImage: "square.and.pencil") {
                        speech.stop(flush: false)
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
            PriceCheckCamera { image in attachment = image; showCamera = false }.ignoresSafeArea()
        }
        .sheet(isPresented: $showProducts) { productSheet }
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
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(Color.mint.opacity(0.13)).frame(width: 112, height: 112)
                Image(systemName: "tag.fill")
                    .font(.system(size: 54, weight: .medium)).rotationEffect(.degrees(-15))
                    .foregroundStyle(Color(red: 0.16, green: 0.52, blue: 0.39))
                Image(systemName: "sparkle").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color(red: 0.67, green: 0.75, blue: 0.26)).offset(x: 44, y: -33)
            }.accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("Good price?\nLet’s find out.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                Text("Show me what you’re looking at.")
                    .font(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { openCamera() } label: { Label("Camera", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { showPhotos = true } label: { Label("Photos", systemImage: "photo") }
            }
            .font(.subheadline.weight(.medium)).buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
        }
        .frame(maxWidth: .infinity).padding(.top, 64).padding(.bottom, 24)
    }

    private func userMessage(_ message: Message) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let image = message.image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            if !message.text.isEmpty {
                Text(message.text).font(.body).lineSpacing(3)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .padding(.leading, 40).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil || !speech.transcript.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recentImage, attachment == nil, recentID != dismissedRecentID {
                HStack(spacing: 10) {
                    Button { attachment = recentImage; dismissedRecentID = recentID } label: {
                        HStack(spacing: 8) {
                            Image(uiImage: recentImage).resizable().scaledToFill().frame(width: 30, height: 30)
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Attach recent photo").font(.subheadline)
                        }
                    }.tint(.primary)
                    Button { dismissedRecentID = recentID } label: { Image(systemName: "xmark").font(.caption) }
                        .tint(.secondary).accessibilityLabel("Hide recent photo")
                }.padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let attachment {
                    HStack(spacing: 8) {
                        Image(uiImage: attachment).resizable().scaledToFill().frame(width: 44, height: 44)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("Photo").font(.subheadline)
                        Button { self.attachment = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .accessibilityLabel("Remove photo")
                    }.padding(6).padding(.trailing, 8).background(.quaternary.opacity(0.4), in: Capsule())
                }
                TextField("Is this a good price?", text: $text, axis: .vertical)
                    .font(.body).lineLimit(1...5).focused($focused)
                    .accessibilityIdentifier("price-check-input").padding(.horizontal, 4).padding(.top, 4)
                if speech.isRecording {
                    Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = speech.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 4) {
                    Menu {
                        Button("Camera", systemImage: "camera") { openCamera() }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        Button("Photos", systemImage: "photo") { showPhotos = true }
                    } label: { Image(systemName: "plus").font(.system(size: 22)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Attach photo")
                    Spacer()
                    Button {
                        if speech.isRecording { speech.stop(flush: true) }
                        else { focused = false; Task { await speech.start() } }
                    } label: {
                        Image(systemName: speech.isRecording ? "stop.fill" : "waveform")
                            .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                    }.accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate question")
                    Button { Task { await check() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 40, height: 40)
                            .background(Color.primary.opacity(canSend && !busy ? 1 : 0.22), in: Circle())
                    }
                    .disabled(busy || !canSend).accessibilityLabel("Check price").accessibilityIdentifier("price-check-send")
                }.tint(.primary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 18, y: 5)
        }
        .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 8)
        .disabled(busy)
    }

    private func pendingReply(_ offer: PriceOffer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let question = offer.question, offer.baseline == nil {
                Text(question).font(.title3).lineSpacing(5)
            } else {
                Text(candidates.isEmpty ? "I haven’t found that in your purchases yet." : "Which one do you mean?")
                    .font(.title3.weight(.medium))
                ForEach(Array(candidates.prefix(3))) { product in
                    Button { Task { await compare(product) } } label: {
                        HStack { Text(product.name); Spacer(); Image(systemName: "arrow.up.left") }
                            .font(.subheadline).padding(.vertical, 10)
                    }.tint(.primary)
                }
                Button("Find a product") { search = ""; showProducts = true }.font(.subheadline).tint(.secondary)
            }
        }
    }

    private var productSheet: some View {
        NavigationStack {
            List(searchResults) { product in
                Button {
                    showProducts = false
                    Task { await compare(product) }
                } label: {
                    HStack {
                        Text(product.name).foregroundStyle(.primary)
                        Spacer()
                        if selected?.id == product.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search your purchases")
            .overlay { if searchResults.isEmpty { ContentUnavailableView.search(text: search) } }
            .navigationTitle("Choose product").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProducts = false } } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func openCamera() {
        speech.stop(flush: true)
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true }
            else { error = "Allow camera access in Settings, or choose a photo instead." }
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
        let previous = offer
        let previousMessages = messages
        let previousComparison = comparison
        let previousProduct = selected
        if let comparison, let selected {
            messages.append(Message(text: "", image: nil, isUser: false, comparison: comparison, product: selected))
        } else if let question = offer?.question {
            messages.append(Message(text: question, image: nil, isUser: false))
        }
        let sent = Message(text: question.isEmpty ? "Is this a good price?" : question, image: data.flatMap(UIImage.init(data:)))
        messages.append(sent)
        if messages.count > 16 { messages.removeFirst(messages.count - 16) }
        offer = nil; comparison = nil; selected = nil
        text = ""; attachment = nil; busy = true; error = nil; focused = false
        defer { busy = false }
        do {
            let result = try await services.api.readPriceOffer(householdId: householdId, text: question, image: data, previous: image == nil ? previous : nil)
            products = try await services.api.fetchProductInsights(householdId: householdId)
            offer = result
            if result.baseline != nil, let match = PriceProductMatcher.exactMatch(name: result.name, products: products) {
                try await loadComparison(match, offer: result)
            }
        } catch {
            if offer == nil {
                messages = previousMessages
                offer = previous; comparison = previousComparison; selected = previousProduct
                text = question; attachment = image
            }
            self.error = "Couldn't check just now. Try again in a moment."
        }
    }

    private func compare(_ product: ProductInsight) async {
        guard let offer, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await loadComparison(product, offer: offer) }
        catch { self.error = "Couldn't load your prices. Try choosing the product again." }
    }

    private func loadComparison(_ product: ProductInsight, offer: PriceOffer) async throws {
        let detail = try await services.api.fetchProductInsight(householdId: householdId, productId: product.id)
        comparison = PriceComparison(offer: offer, purchases: detail.purchases)
        selected = product
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

/// An answer in the conversation, not a dashboard card.
private struct PriceCheckReply: View {
    let comparison: PriceComparison
    let product: ProductInsight
    var changeProduct: (() -> Void)? = nil
    @State private var perUnit = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var change: Double? { comparison.changeFromAverage }
    private var verdict: String {
        guard let change else { return "No price to compare yet." }
        if change > 5 { return "A bit steep." }
        if change < -5 { return "Good price." }
        return "About right."
    }
    private var verdictColor: Color {
        guard let change else { return .primary }
        if change > 5 { return Color(red: 0.78, green: 0.32, blue: 0.20) }
        if change < -5 { return Color(red: 0.18, green: 0.55, blue: 0.39) }
        return .primary
    }
    private var unitLabel: String {
        switch comparison.offer.unit {
        case "mL": return "100 mL"
        case "g": return "100 g"
        default: return "each"
        }
    }
    private func display(_ value: Double) -> Double {
        perUnit ? value : (comparison.priceForOfferPack(value) ?? value)
    }
    private func money(_ value: Double) -> String { value.formatted(.currency(code: "AUD").precision(.fractionLength(2))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                if let changeProduct {
                    Button(action: changeProduct) {
                        HStack(spacing: 6) {
                            Text(product.name)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("Change product").accessibilityIdentifier("price-check-change-product")
                } else { Text(product.name).font(.subheadline).foregroundStyle(.secondary) }
                Text(verdict).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .tracking(-0.8).foregroundStyle(verdictColor)
                if let change {
                    Text(abs(change) < 1 ? "Right around your average." : "\(abs(change).formatted(.number.precision(.fractionLength(0))))% \(change > 0 ? "above" : "below") your average.")
                        .font(.title3).accessibilityIdentifier("price-check-verdict")
                } else {
                    Text("I don’t have a comparable price for this one yet.")
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            if let baseline = comparison.offer.baseline, let average = comparison.average {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { unitOptions }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { unitOptions }
                }.padding(4).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 24))
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { metrics(baseline.value, average) }
                    VStack(alignment: .leading, spacing: 18) { metrics(baseline.value, average) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        priceBar("This price", value: baseline.value, maxValue: max(baseline.value, average), color: verdictColor)
                        priceBar("Average", value: average, maxValue: max(baseline.value, average), color: Color.primary.opacity(0.18))
                    }.accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var unitOptions: some View {
        unitButton(comparison.offer.packSizeLabel.map { "\($0) pack" } ?? "Pack", selected: !perUnit) { perUnit = false }
        unitButton("Per \(unitLabel)", selected: perUnit) { perUnit = true }
    }

    @ViewBuilder private func metrics(_ offer: Double, _ average: Double) -> some View {
        metric("This price", offer)
        metric("Average", average)
        if let usual = comparison.usual { metric("Usual", usual) }
        else if let lowest = comparison.lowest { metric("Best", lowest) }
    }
    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(money(display(value))).font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit().fixedSize().contentTransition(.numericText())
        }.accessibilityElement(children: .combine)
    }
    private func unitButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? Color(.systemBackground) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func priceBar(_ label: String, value: Double, maxValue: Double, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            GeometryReader { geometry in
                Capsule().fill(color).frame(width: max(4, geometry.size.width * value / maxValue))
            }.frame(height: 6)
        }
    }
}
