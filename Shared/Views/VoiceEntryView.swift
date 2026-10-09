import SwiftUI

struct VoiceEntryButton: View {
    @State private var showingVoice = false

    var body: some View {
        Button { showingVoice = true } label: {
            Image(systemName: "mic.fill")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("Add items by voice")
        .help("Add items by voice")
        .sheet(isPresented: $showingVoice) { VoiceEntryView() }
    }
}

private struct VoiceDraft: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String
}

struct VoiceEntryView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var speech = SpeechService()
    @State private var drafts: [VoiceDraft] = []
    @State private var working = false
    @State private var reviewed = false
    @State private var usedModel = false
    @State private var work: Task<Void, Never>?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(reviewed ? "Review items" : "Add by voice").font(.title2.bold())
                Spacer()
                Button("Cancel") { speech.stop(); work?.cancel(); dismiss() }
                    .disabled(working && reviewed)
            }
            Text(reviewed ? "Check the names and quantities before adding." : "Try “2 apples” or “milk, butter and eggs”. Nothing is added until you confirm.")
                .foregroundStyle(.secondary)

            if reviewed {
                if drafts.isEmpty {
                    Text("No clear shopping items heard. Try saying just the items you want to buy.")
                        .padding(.vertical)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($drafts) { $draft in
                                HStack {
                                    TextField("Item", text: $draft.name)
                                    TextField("Qty", text: $draft.quantity).frame(width: 80)
                                    Button {
                                        drafts.removeAll { $0.id == draft.id }
                                    } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove \(draft.name)")
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .disabled(working)
                }
                Text(usedModel ? "Shopping items filtered on this device with Apple Intelligence." : "Basic on-device filtering is in use. It may miss unfamiliar products; you can type those into the list.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(speech.transcript.isEmpty ? (speech.isRecording ? "Listening…" : "Ready to listen") : speech.transcript)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(20)
                }
                .frame(height: 190)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .bottom) {
                    if speech.isRecording {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(LinearGradient(colors: [.cyan, .blue, .purple, .pink, .orange], startPoint: .leading, endPoint: .trailing))
                            .frame(height: reduceMotion ? 10 : 12 + CGFloat(speech.level) * 55)
                            .blur(radius: 14)
                            .opacity(0.8)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: speech.level)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                Text("The microphone stops after 45 seconds. Audio stays on your device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = saveError ?? speech.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if working || speech.isStarting { ProgressView().controlSize(.small) }
                if reviewed {
                    Button("Try again") {
                        drafts = []; reviewed = false; saveError = nil
                        work = Task { await speech.start() }
                    }
                    Spacer()
                    Button("Add \(drafts.count) items") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(drafts.isEmpty || drafts.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                } else {
                    if !speech.isRecording {
                        Button("Listen again") { work = Task { await speech.start() } }
                    }
                    Spacer()
                    Button(speech.isRecording ? "Stop & review" : "Review items") { review() }
                        .buttonStyle(.borderedProminent)
                        .disabled(speech.transcript.isEmpty)
                }
            }
            .disabled(working || speech.isStarting)
        }
        .padding(24)
        .frame(idealWidth: 460)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 360)
        #endif
        .interactiveDismissDisabled(working && reviewed)
        .task { await speech.start() }
        .onDisappear { speech.stop(); work?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { speech.stop() } }
    }

    private func review() {
        working = true
        work = Task {
            await speech.finish()
            let result = await VoiceShoppingParser.parse(speech.transcript)
            guard !Task.isCancelled else { return }
            drafts = result.items.map { VoiceDraft(name: $0.name, quantity: $0.quantity ?? "") }
            usedModel = result.usedModel
            reviewed = true
            working = false
        }
    }

    private func save() {
        working = true
        saveError = nil
        let pending = drafts
        work = Task {
            for draft in pending {
                guard !Task.isCancelled else { break }
                if await services.shopping.addItem(name: draft.name, quantity: draft.quantity.isEmpty ? nil : draft.quantity) {
                    drafts.removeAll { $0.id == draft.id }
                }
            }
            working = false
            if drafts.isEmpty { dismiss() }
            else { saveError = "Some items couldn't be saved. Check your connection and try again." }
        }
    }
}
