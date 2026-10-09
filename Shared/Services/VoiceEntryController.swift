import Foundation
import Observation

@MainActor
@Observable final class VoiceEntryController {
    let speech = SpeechService()
    private(set) var feedbackID = UUID()
    private(set) var status: String? { didSet { feedbackID = UUID() } }
    private(set) var isWorking = false
    private(set) var lastAdded: [ShoppingItem] = []
    private(set) var isUndoing = false
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var store: ShoppingListStore?
    private var householdID: String?
    private var sessionID = UUID()

    var isActive: Bool { speech.isRecording || speech.isStarting }
    var canUndo: Bool { !lastAdded.isEmpty && !isWorking && !isUndoing }
    var displayText: String {
        if !speech.transcript.isEmpty { return speech.transcript }
        return speech.isStarting ? "Starting…" : "Listening…"
    }

    func dismissFeedback() {
        status = nil
        speech.error = nil
        lastAdded = []
    }

    func start(store: ShoppingListStore) {
        guard !isActive else { return }
        self.store = store
        householdID = store.householdId
        guard householdID != nil else { speech.error = "Wait for your list to load, then try again."; return }
        status = nil
        speech.onUtterance = { [weak self] phrase in
            guard let self else { return }
            self.queue.append(phrase)
            self.drainQueue()
        }
        startup = Task { await speech.start() }
    }

    func stop(discardPending: Bool = false) {
        startup?.cancel()
        speech.stop(flush: !discardPending)
        if discardPending {
            sessionID = UUID()
            worker?.cancel()
            worker = nil
            queue.removeAll()
            isWorking = false
            dismissFeedback()
        }
    }

    private func drainQueue() {
        guard worker == nil, !isUndoing, let store else { return }
        let token = sessionID
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty && !Task.isCancelled {
                let phrase = self.queue.removeFirst()
                self.isWorking = true
                let result = await VoiceShoppingParser.parse(phrase)
                guard !Task.isCancelled, self.sessionID == token,
                      store.householdId == self.householdID else { break }
                if result.items.isEmpty {
                    continue
                }
                var added: [ShoppingItem] = []
                var failed = false
                for item in result.items {
                    guard !Task.isCancelled else { break }
                    let key = Self.nameKey(item.name)
                    // Recognition restarts and repeated requests must not create
                    // duplicates already on the household's active list.
                    guard !store.items.contains(where: { !$0.checked && Self.nameKey($0.name) == key }) else { continue }
                    if let saved = await store.addItem(name: item.name, quantity: item.quantity) {
                        added.append(saved)
                    } else {
                        failed = true
                    }
                }
                if !added.isEmpty {
                    self.lastAdded = added
                    self.status = added.count == 1 ? "Added \(added[0].name)" : "Added \(added.count) items"
                } else if !failed {
                    self.status = "Already on your list"
                }
                if failed {
                    self.status = "Couldn't save everything. Try those items again."
                    self.speech.stop()
                    self.queue.removeAll()
                }
            }
            guard self.sessionID == token else { return }
            self.isWorking = false
            self.worker = nil
        }
    }

    func undo() async {
        guard canUndo, let store else { return }
        isUndoing = true
        let batch = lastAdded
        for item in batch {
            guard store.items.contains(where: { $0.id == item.id && !$0.checked }) else {
                lastAdded.removeAll { $0.id == item.id }
                continue
            }
            if await store.deleteItem(item) { lastAdded.removeAll { $0.id == item.id } }
        }
        status = lastAdded.isEmpty ? "Undone" : "Couldn't undo everything. Try again."
        isUndoing = false
        drainQueue()
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
