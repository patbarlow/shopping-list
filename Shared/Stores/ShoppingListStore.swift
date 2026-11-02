import Foundation
import Observation

@MainActor
protocol ShoppingListAPI: AnyObject {
    var currentUser: User? { get }
    func fetchItems(householdId: String) async throws -> [ShoppingItem]
    func createItem(id: String?, householdId: String, name: String, quantity: String?, notes: String?) async throws -> ShoppingItem
    func createBulkItems(householdId: String, items: [[String: Any]]) async throws -> [ShoppingItem]
    func patchItem(id: String, fields: [String: Any]) async throws -> ShoppingItem
    func completeItem(id: String) async throws
    func undoCompleteItem(id: String) async throws -> ShoppingItem
    func deleteItem(id: String) async throws
}

@MainActor
protocol ShoppingListRealtime: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    var onReconnect: (() -> Void)? { get set }
    func connect(householdId: String)
}

@MainActor
@Observable final class ShoppingListStore {
    var items: [ShoppingItem] = []
    var isLoading    = false
    private(set) var hasLoaded = false
    var error: String?
    private(set) var householdId: String?

    private(set) var recentlyCompleted: [ShoppingItem] = []
    private(set) var undoDeadline: Date? = nil
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?

    @ObservationIgnored private var completionTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var completionTokens: [String: UUID] = [:]
    @ObservationIgnored private var completionIntent: [String: Bool] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var fetchSequence = 0
    @ObservationIgnored private var itemVersions: [String: String] = [:]
    @ObservationIgnored private var deferredCompletionEvents: [String: (String, [String: Any])] = [:]
    private let api: any ShoppingListAPI
    private let realtime: any ShoppingListRealtime

    init(api: any ShoppingListAPI, realtime: any ShoppingListRealtime) {
        self.api      = api
        self.realtime = realtime
    }

    // MARK: - Computed

    var groupedItems: [(category: ItemCategory, items: [ShoppingItem])] {
        ItemCategory.allCases
            .sorted { $0.aisleOrder < $1.aisleOrder }
            .compactMap { cat in
                let bucket = items
                    .filter { !$0.checked }
                    .filter { $0.category == cat }
                    .sorted { a, b in
                        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                return bucket.isEmpty ? nil : (category: cat, items: bucket)
            }
    }

    var allKnownNames: [String] {
        let fromItems = items.map(\.name)
        let fromHistory = (UserDefaults.sharedGroup.array(forKey: "item_name_history") as? [String]) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for name in fromItems + fromHistory {
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    // MARK: - Lifecycle

    func load(householdId: String) async {
        if self.householdId != householdId {
            items = []; hasLoaded = false; error = nil
        }
        self.householdId = householdId

        realtime.onEvent = { [weak self] action, record in
            self?.applyEvent(action: action, record: record)
        }
        realtime.onReconnect = { [weak self] in
            Task { await self?.fetch() }
        }

        realtime.connect(householdId: householdId)
        await fetch()
    }

    func fetch() async {
        guard let householdId else { return }
        fetchSequence += 1
        let sequence = fetchSequence
        let startRevision = revision
        isLoading = true
        defer { if sequence == fetchSequence { isLoading = false } }
        do {
            var fetched = try await api.fetchItems(householdId: householdId)
            guard self.householdId == householdId, sequence == fetchSequence else { return }
            // A response started before a live event must never undo that event.
            guard revision == startRevision else {
                await fetch()
                return
            }
            for (id, completed) in completionIntent {
                fetched.removeAll { $0.id == id }
                if !completed, let local = items.first(where: { $0.id == id }) {
                    fetched.append(local)
                }
            }
            items = fetched
            hasLoaded = true
            error = nil
            for item in fetched { itemVersions[item.id] = item.updatedAt }
        } catch {
            guard self.householdId == householdId, sequence == fetchSequence else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Realtime event application

    private func applyEvent(action: String, record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let item = try? JSONDecoder().decode(ShoppingItem.self, from: data)
        else {
            Task { await fetch() }
            return
        }
        guard item.householdId == householdId else { return }
        if let version = itemVersions[item.id], item.updatedAt < version { return }
        revision += 1
        itemVersions[item.id] = item.updatedAt
        guard completionIntent[item.id] == nil else {
            deferredCompletionEvents[item.id] = (action, record)
            return
        }

        switch action {
        case "create", "update":
            if item.checked {
                items.removeAll { $0.id == item.id }
            } else if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = item
            } else {
                items.append(item)
            }

        case "delete":
            items.removeAll { $0.id == item.id }

        default:
            break
        }
    }

    // MARK: - Name helpers

    static func extractQuantity(from raw: String) -> (name: String, qty: String?) {
        let item = ShoppingInputParser.parse(raw)
        return (item.name, item.quantity)
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Add

    @discardableResult
    func addItem(name: String, quantity: String? = nil, notes: String? = nil) async -> ShoppingItem? {
        var itemName = name.trimmingCharacters(in: .whitespaces)
        let explicitQty = quantity?.trimmingCharacters(in: .whitespaces)
        var itemQty: String?

        if let q = explicitQty, !q.isEmpty {
            itemQty = q
        } else {
            let parsed = Self.extractQuantity(from: itemName)
            itemName = parsed.name
            itemQty  = parsed.qty
        }
        itemName = Self.capitalizeFirst(itemName)

        let trimmed = itemName
        guard !trimmed.isEmpty, let householdId else { return nil }

        recordInHistory(trimmed)

        let itemId = UUID().uuidString.lowercased()
        let placeholder = ShoppingItem(
            id:          itemId,
            name:        trimmed,
            quantity:    itemQty,
            notes:       notes,
            householdId: householdId,
            addedBy:     api.currentUser?.id ?? ""
        )
        items.append(placeholder)

        do {
            let serverItem = try await api.createItem(
                id:          itemId,
                householdId: householdId,
                name:        trimmed,
                quantity:    itemQty,
                notes:       notes
            )
            // Server may normalise the name (via existing product record)
            if let idx = items.firstIndex(where: { $0.id == itemId }) {
                items[idx] = serverItem
            } else if !items.contains(where: { $0.id == serverItem.id }) {
                items.append(serverItem)
            }
            return serverItem
        } catch {
            items.removeAll { $0.id == itemId }
            self.error = error.localizedDescription
            return nil
        }
    }

    func addBulkItems(_ ingredients: [EditableIngredient]) async throws {
        guard let householdId else { return }
        let userId = api.currentUser?.id ?? ""

        let toMerge = ingredients.filter { $0.existingItemId != nil }
        let toCreate = ingredients.filter { $0.existingItemId == nil }

        // Merge into existing list items by patching their quantity
        for ing in toMerge {
            guard let existingId = ing.existingItemId else { continue }
            let mergedQty = EditableIngredient.mergeQuantities(ing.existingListQty, ing.currentQuantity)
            recordInHistory(ing.name.trimmingCharacters(in: .whitespaces))

            // Optimistic update
            if let idx = items.firstIndex(where: { $0.id == existingId }) {
                items[idx].quantity = mergedQty
            }

            if let updated = try? await api.patchItem(id: existingId, fields: ["quantity": mergedQty ?? ""]) {
                if let idx = items.firstIndex(where: { $0.id == existingId }) {
                    items[idx] = updated
                }
            }
        }

        guard !toCreate.isEmpty else { return }

        // Optimistic insert with parsed categories so they land in the right aisle
        var placeholders: [ShoppingItem] = []
        for ing in toCreate {
            let trimmed = ing.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let id = UUID().uuidString.lowercased()
            var placeholder = ShoppingItem(
                id: id, name: trimmed,
                quantity: ing.currentQuantity,
                notes: nil,
                householdId: householdId,
                addedBy: userId
            )
            placeholder.category   = ItemCategory(rawValue: ing.category) ?? .other
            placeholder.aisleOrder = ing.aisleOrder
            placeholders.append(placeholder)
            items.append(placeholder)
            recordInHistory(trimmed)
        }

        let apiItems: [[String: Any]] = placeholders.map { p in
            var dict: [String: Any] = [
                "id": p.id, "name": p.name,
                "category": p.category.rawValue,
                "aisle_order": p.aisleOrder
            ]
            if let q = p.quantity, !q.isEmpty { dict["quantity"] = q }
            return dict
        }

        do {
            let serverItems = try await api.createBulkItems(householdId: householdId, items: apiItems)
            for serverItem in serverItems {
                if let idx = items.firstIndex(where: { $0.id == serverItem.id }) {
                    items[idx] = serverItem
                }
            }
        } catch {
            let ids = Set(placeholders.map(\.id))
            items.removeAll { ids.contains($0.id) }
            throw error
        }
    }

    // MARK: - Complete / Undo (3-second window)

    func pendingToggle(_ item: ShoppingItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        recentlyCompleted.append(item)
        syncCompletion(item, completed: true)
        scheduleFinalizeDebounced()
    }

    func undoLastComplete() {
        guard let item = recentlyCompleted.popLast() else { return }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        syncCompletion(item, completed: false)
        if recentlyCompleted.isEmpty {
            finalizeTask?.cancel()
            finalizeTask = nil
            undoDeadline = nil
        } else {
            scheduleFinalizeDebounced()
        }
    }

    private func scheduleFinalizeDebounced() {
        finalizeTask?.cancel()
        undoDeadline = Date().addingTimeInterval(3.0)
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            self.recentlyCompleted.removeAll()
            self.undoDeadline = nil
            self.finalizeTask = nil
        }
    }

    private func syncCompletion(_ item: ShoppingItem, completed: Bool) {
        revision += 1
        let previous = completionTasks[item.id]
        let token = UUID()
        completionTokens[item.id] = token
        completionIntent[item.id] = completed
        completionTasks[item.id] = Task { [weak self] in
            // Undo (and a second tick) must reach the server in tap order.
            await previous?.value
            guard let self else { return }
            var failureMessage: String?
            do {
                var restored: ShoppingItem?
                if completed {
                    try await api.completeItem(id: item.id)
                } else {
                    restored = try await api.undoCompleteItem(id: item.id)
                }
                guard completionTokens[item.id] == token else { return }
                if householdId == item.householdId {
                    items.removeAll { $0.id == item.id }
                    if let restored {
                        items.insert(restored, at: 0)
                        itemVersions[item.id] = max(itemVersions[item.id] ?? "", restored.updatedAt)
                    }
                }
            } catch {
                guard completionTokens[item.id] == token else { return }
                failureMessage = error.localizedDescription
                self.error = error.localizedDescription
                recentlyCompleted.removeAll { $0.id == item.id }
                if recentlyCompleted.isEmpty {
                    finalizeTask?.cancel()
                    finalizeTask = nil
                    undoDeadline = nil
                }
                // Show the item again on a failed completion. Reconcile with
                // the server below, including ambiguous network failures.
                if completed, householdId == item.householdId,
                   !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            }
            completionTasks[item.id] = nil
            completionTokens[item.id] = nil
            completionIntent[item.id] = nil
            revision += 1
            if let (action, record) = deferredCompletionEvents.removeValue(forKey: item.id) {
                applyEvent(action: action, record: record)
            }
            // Resolve an interrupted request whose write reached the server
            // but whose response was lost. Successful ticks need no re-fetch.
            if let failureMessage {
                await fetch()
                if householdId == item.householdId { error = failureMessage }
            }
        }
    }

    // MARK: - Edit

    func updateItem(_ item: ShoppingItem, name: String, quantity: String?, notes: String?) async {
        var fields: [String: Any] = ["name": name]
        fields["quantity"] = quantity ?? ""
        fields["notes"]    = notes    ?? ""
        if let updated = try? await api.patchItem(id: item.id, fields: fields) {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = updated
            }
        }
    }

    // MARK: - Delete ("didn't buy it")

    @discardableResult
    func deleteItem(_ item: ShoppingItem) async -> Bool {
        if let idx = recentlyCompleted.firstIndex(where: { $0.id == item.id }) {
            recentlyCompleted.remove(at: idx)
            if recentlyCompleted.isEmpty { finalizeTask?.cancel(); finalizeTask = nil }
        }

        items.removeAll { $0.id == item.id }
        do {
            try await api.deleteItem(id: item.id)
            return true
        } catch {
            items.append(item)
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - History

    private func recordInHistory(_ name: String) {
        var history = (UserDefaults.sharedGroup.array(forKey: "item_name_history") as? [String]) ?? []
        history.removeAll { $0.lowercased() == name.lowercased() }
        history.insert(name, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.sharedGroup.set(history, forKey: "item_name_history")
    }
}
