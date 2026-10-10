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
    private var api: APIService?
    private var recipeChoices: [SavedRecipe] = []
    private var requestedServings: Int?
    private var householdID: String?
    private var sessionID = UUID()

    var isActive: Bool { speech.isRecording || speech.isStarting }
    var canUndo: Bool { !lastAdded.isEmpty && !isWorking && !isUndoing }
    var displayText: String {
        if speech.isSpeaking { return "Speaking…" }
        if !speech.transcript.isEmpty { return speech.transcript }
        return speech.isStarting ? "Starting…" : "Listening…"
    }

    func dismissFeedback() {
        status = nil
        speech.error = nil
        lastAdded = []
    }

    func start(store: ShoppingListStore, api: APIService) {
        guard !isActive else { return }
        self.store = store
        self.api = api
        recipeChoices = []
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
            recipeChoices = []
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
                let command = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if ["stop listening", "stop", "that's all", "that’s all"].contains(command) {
                    self.queue.removeAll()
                    self.speech.stop()
                    self.status = "Voice input finished"
                    break
                }
                if ["cancel", "never mind", "nevermind"].contains(command) {
                    self.recipeChoices = []
                    self.status = "Cancelled"
                    continue
                }
                var recipeName: String?
                var items: [ShoppingInputParser.Item]
                if let request = VoiceRecipeRequest.parse(phrase) {
                    self.recipeChoices = []
                    self.requestedServings = request.servings
                    guard let resolved = await self.recipeItems(named: request.name, token: token) else { continue }
                    items = resolved.items
                    recipeName = resolved.name
                } else if !self.recipeChoices.isEmpty {
                    // A follow-up selects only from the recipes we just offered.
                    guard let resolved = await self.recipeItems(named: phrase, token: token) else { continue }
                    items = resolved.items
                    recipeName = resolved.name
                } else {
                    items = await VoiceShoppingParser.parse(phrase).items
                }
                guard !Task.isCancelled, self.sessionID == token,
                      store.householdId == self.householdID else { break }
                if items.isEmpty {
                    continue
                }
                var added: [ShoppingItem] = []
                var failed = false
                for item in items {
                    guard !Task.isCancelled, store.householdId == self.householdID else { break }
                    let key = Self.nameKey(item.name)
                    // Recognition restarts and repeated requests must not create
                    // duplicates already on the household's active list.
                    guard !store.items.contains(where: { !$0.checked && Self.nameKey($0.name) == key }) else { continue }
                    if let saved = await store.addItem(name: item.name, quantity: item.quantity) {
                        added.append(saved)
                        self.speech.chime()
                    } else {
                        failed = true
                    }
                }
                guard !Task.isCancelled, self.sessionID == token,
                      store.householdId == self.householdID else { break }
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
                } else if let recipeName {
                    self.reply(added.isEmpty ? "Those ingredients are already on your list." : "Added \(added.count) ingredients for \(recipeName).")
                }
            }
            guard self.sessionID == token else { return }
            self.isWorking = false
            self.worker = nil
        }
    }

    private func reply(_ message: String) {
        status = message
        speech.say(message)
    }

    private func recipeItems(named query: String, token: UUID) async -> (name: String, items: [ShoppingInputParser.Item])? {
        guard let api, let householdID else { return nil }
        do {
            let recipes: [SavedRecipe]
            if recipeChoices.isEmpty {
                recipes = try await api.fetchSavedRecipes(householdId: householdID)
            } else {
                recipes = recipeChoices
            }
            guard !Task.isCancelled, sessionID == token, store?.householdId == householdID else { return nil }
            let matches = VoiceRecipeRequest.matches(query, recipes: recipes)
            guard matches.count == 1, let recipe = matches.first else {
                if matches.isEmpty {
                    reply(recipeChoices.isEmpty ? "I couldn't find that saved recipe. Import its link in Recipes first." : "Say the recipe name, or say cancel.")
                } else {
                    recipeChoices = matches
                    reply("Which recipe? " + matches.prefix(3).map(\.name).joined(separator: ", "))
                }
                return nil
            }
            let detail = try await api.fetchRecipe(id: recipe.id, householdId: householdID)
            guard !Task.isCancelled, sessionID == token, store?.householdId == householdID else { return nil }
            recipeChoices = []
            guard !detail.ingredients.isEmpty else {
                reply("That saved recipe has no ingredients. Import its link again first.")
                return nil
            }
            var factor = 1.0
            if let servings = requestedServings {
                guard (1...100).contains(servings), let original = detail.defaultServings, original > 0 else {
                    reply("I couldn't scale that recipe. Check its servings in Recipes first.")
                    return nil
                }
                factor = Double(servings) / Double(original)
            }
            let items = detail.ingredients.filter { !RecipeStaples.contains($0.name) && $0.existingItemId == nil }.map {
                ShoppingInputParser.Item(name: $0.name, quantity: EditableIngredient.scaleQuantity($0.quantity, by: factor))
            }
            if items.isEmpty { reply("Nothing to add. That recipe only needs pantry basics or items already on your list.") }
            return (detail.recipeName, items)
        } catch {
            guard !Task.isCancelled, sessionID == token, store?.householdId == householdID else { return nil }
            reply("I couldn't load that recipe. Try again in a moment.")
            return nil
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
