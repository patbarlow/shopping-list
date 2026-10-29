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
    @State private var mediaSource: MediaPickerSource?
    @Namespace private var mediaTransition
    @State private var mediaOrigin = "attachments"
    @State private var showAttachments = false
    @State private var focusAfterMedia = false
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
    @State private var recentDate: Date?
    @State private var dismissedRecentID: String?
    @State private var messages: [Message] = []
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
        if let matches = offer?.historyMatches, !matches.isEmpty {
            let ids = Set(matches.map(\.productId))
            return products.filter { ids.contains($0.id) }
        }
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
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(messages.isEmpty && offer == nil)
            .overlay {
                if messages.isEmpty, offer == nil, error == nil, !busy,
                   !focused, attachment == nil, text.isEmpty {
                    introduction.transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
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
                    Button("New chat", hugeIcon: "square.and.pencil") {
                        speech.stop(flush: false)
                        messages = []; offer = nil; comparison = nil; selected = nil; attachment = nil; text = ""; error = nil
                    }.disabled(busy)
                } label: { Image(hugeIcon: "ellipsis") }
                .accessibilityLabel("Chat options")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(item: $mediaSource, onDismiss: {
            if focusAfterMedia { focused = true; focusAfterMedia = false }
        }) { source in
            Group {
                switch source {
                case .camera, .scan: CompactCameraPicker(scan: source == .scan, onCapture: attach)
                case .photos: CompactPhotoPicker(onSelect: attach)
                }
            }
            .navigationTransition(.zoom(sourceID: mediaOrigin, in: mediaTransition))
        }
        .sheet(isPresented: $showProducts) { productSheet }
        .task {
            speech.onUtterance = { phrase in text += (text.isEmpty ? "" : " ") + phrase }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await loadRecent(requestPermission: true) }
            else { speech.stop(flush: true) }
        }
        .task(id: recentID) {
            guard let recentDate else { return }
            let remaining = max(0, recentDate.addingTimeInterval(RecentPhotoPolicy.maxAge).timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            recentImage = nil; recentID = nil
        }
        .onChange(of: text) { _, value in if !value.isEmpty { dismissedRecentID = recentID } }
        .onChange(of: speech.transcript) { _, value in if !value.isEmpty { dismissedRecentID = recentID } }
        .onDisappear { speech.stop(flush: true); showAttachments = false }
    }

    private var introduction: some View {
        VStack(spacing: 24) {
            TrolleyMascot(size: 112)
            VStack(spacing: 12) {
                Text("Good price?\nLet’s find out.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                Text("Show me what you’re looking at.")
                    .font(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { openMedia(.camera, origin: "camera") } label: { Label("Camera", hugeIcon: "camera") }
                    .matchedTransitionSource(id: "camera", in: mediaTransition)
                Button { openMedia(.photos, origin: "photos") } label: { Label("Photos", hugeIcon: "photo") }
                    .matchedTransitionSource(id: "photos", in: mediaTransition)
            }
            .font(.subheadline.weight(.medium)).buttonStyle(PriceCheckMediaButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24)
        .accessibilityIdentifier("price-check-introduction")
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
            if let recentImage, attachment == nil, text.isEmpty, recentID != dismissedRecentID {
                HStack(spacing: 10) {
                    Button { attach(recentImage); focused = true; focusAfterMedia = false } label: {
                        HStack(spacing: 8) {
                            Image(uiImage: recentImage).resizable().scaledToFill().frame(width: 30, height: 30)
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Attach recent photo").font(.subheadline)
                        }
                    }.tint(.primary)
                }.padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let attachment {
                    HStack(spacing: 8) {
                        Image(uiImage: attachment).resizable().scaledToFill().frame(width: 44, height: 44)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("Photo").font(.subheadline)
                        Button { AppHaptics.selection(); self.attachment = nil } label: { Image(hugeIcon: "xmark").font(.caption.weight(.semibold)) }
                            .accessibilityLabel("Remove photo")
                    }.padding(6).padding(.trailing, 8)
                        .background(TrolleyStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(.scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity))
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
                    Button {
                        AppHaptics.tap()
                        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9)) { showAttachments = true }
                    } label: {
                        Image(hugeIcon: "plus").frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                        .buttonStyle(.plain)
                        .background {
                            AttachmentMenuPresenter(isPresented: $showAttachments,
                                // Keep the source menu in place during its zoom;
                                // dismissing the keyboard here would move it first.
                                onOpenMedia: { speech.stop(flush: true) },
                                onSelect: attach,
                                onFinish: { focused = true; focusAfterMedia = false })
                        }
                        .accessibilityLabel("Attach photo").accessibilityIdentifier("price-check-attachments")
                    Spacer()
                    Button {
                        AppHaptics.tap()
                        if speech.isRecording { speech.stop(flush: true) }
                        else { focused = false; Task { await speech.start() } }
                    } label: {
                        Image(hugeIcon: speech.isRecording ? "stop.fill" : "waveform")
                            .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                    }.accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate question")
                    Button { Task { await check() } } label: {
                        Image(hugeIcon: "arrow.up").font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 40, height: 40)
                            .background(Color.primary.opacity(canSend && !busy ? 1 : 0.22), in: Circle())
                    }
                    .disabled(busy || !canSend).accessibilityLabel("Check price").accessibilityIdentifier("price-check-send")
                }.tint(.primary)
            }
            .padding(14)
            .trolleyComposer()
        }
        .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 8)
        .disabled(busy)
        .contentShape(Rectangle())
        .background(ComposerKeyboardDismissal(enabled: focused) { focused = false })
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
                        HStack { Text(product.name); Spacer(); Image(hugeIcon: "arrow.up.left") }
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
                        if selected?.id == product.id { Image(hugeIcon: "checkmark").foregroundStyle(.secondary) }
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

    private func openMedia(_ source: MediaPickerSource, origin: String) {
        AppHaptics.tap()
        speech.stop(flush: true)
        focused = false
        mediaOrigin = origin
        mediaSource = source
    }

    private func attach(_ image: UIImage) {
        AppHaptics.added()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { attachment = image }
        dismissedRecentID = recentID
        focusAfterMedia = true
        error = nil
    }

    private func check() async {
        speech.stop(flush: true)
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty || attachment != nil else { return }
        guard question.count <= 2000 else { error = "Please keep your question under 2,000 characters."; return }
        AppHaptics.sent()
        dismissedRecentID = recentID
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
            let matchedID = result.historyMatches?.count == 1 ? result.historyMatches?.first?.productId : nil
            let match = products.first { $0.id == matchedID } ?? (result.historyMatches == nil ? PriceProductMatcher.exactMatch(name: result.name, products: products) : nil)
            if result.baseline != nil, let match { try await loadComparison(match, offer: result) }
            AppHaptics.success()
        } catch {
            if offer == nil {
                messages = previousMessages
                offer = previous; comparison = previousComparison; selected = previousProduct
                text = question; attachment = image
            }
            AppHaptics.error()
            self.error = priceCheckErrorMessage(error)
        }
    }

    private func priceCheckErrorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized: return "Your sign-in has expired. Sign in again in Settings, then retry."
            case .notFound: return "Price check couldn’t connect. Your photo is still here — please try again."
            case .serverError("could_not_read_offer"): return "I couldn’t read the price. Try a closer photo, or type the product and price."
            case .serverError("price_reader_unavailable"): return "The price reader is unavailable just now. Your photo is ready to retry."
            default: break
            }
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            return "You’re offline. Reconnect and send again — your photo is still here."
        }
        return "Couldn't check just now. Your message is ready to retry."
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
        comparison = PriceComparison(offer: offer, purchases: offer.matchingPurchases(detail.purchases, productId: product.id))
        selected = product
    }
    private func loadRecent(requestPermission: Bool = false) async {
        #if DEBUG
        if let scenario = ProcessInfo.processInfo.environment["TROLLEY_UI_TEST"] {
            if scenario == "price-recent", recentID == nil {
                recentDate = .now
                recentID = "fixture-recent-photo"
                recentImage = UIImage(named: "TrolleyMascot")
            }
            return
        }
        #endif
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestPermission, status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            recentImage = nil; recentID = nil
            return
        }
        let photo = await RecentPhotoLoader.shared.latest()
        guard !Task.isCancelled else { return }
        guard let photo, RecentPhotoPolicy.isEligible(photo.date) else { recentID = nil; recentImage = nil; return }
        if !text.isEmpty || attachment != nil || busy { dismissedRecentID = photo.id }
        recentDate = photo.date
        recentID = photo.id; recentImage = photo.image
    }
}

/// Photo-library queries can synchronously connect to the Photos daemon after
/// idle. Keep them off the main actor, and reuse the image while its asset matches.
private actor RecentPhotoLoader {
    struct Photo: Sendable {
        let id: String
        let date: Date?
        let image: UIImage
    }
    static let shared = RecentPhotoLoader()
    private var cached: Photo?

    func latest() async -> Photo? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(format: "creationDate > %@ AND creationDate <= %@", Date().addingTimeInterval(-RecentPhotoPolicy.maxAge) as NSDate, Date() as NSDate)
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { cached = nil; return nil }
        if cached?.id == asset.localIdentifier { return cached }
        let request = PHImageRequestOptions()
        request.deliveryMode = .highQualityFormat
        request.isNetworkAccessAllowed = true
        let image: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: request) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                continuation.resume(returning: image)
            }
        }
        guard let image, RecentPhotoPolicy.isEligible(asset.creationDate) else { cached = nil; return nil }
        let photo = Photo(id: asset.localIdentifier, date: asset.creationDate, image: image)
        cached = photo
        return photo
    }
}

private struct PriceCheckMediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(TrolleyStyle.surface.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
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
                            Image(hugeIcon: "chevron.down").font(.caption2.weight(.semibold))
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
