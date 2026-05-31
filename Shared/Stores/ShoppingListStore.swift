import Foundation
import Observation

@MainActor
@Observable final class ShoppingListStore {
    var items: [ShoppingItem] = []
    var isLoading    = false
    var error: String?
    private(set) var householdId: String?

    var showCompleted: Bool = false {
        didSet { UserDefaults.standard.set(showCompleted, forKey: "show_completed") }
    }

    private(set) var pendingCompleteIDs: Set<String> = []
    @ObservationIgnored private var pendingTasks: [String: Task<Void, Never>] = [:]

    private let api: APIService
    private let realtime: RealtimeService

    init(api: APIService, realtime: RealtimeService) {
        self.api      = api
        self.realtime = realtime
        let key = "show_completed"
        if UserDefaults.standard.object(forKey: key) == nil {
            #if os(macOS)
            self.showCompleted = true
            #else
            self.showCompleted = false
            #endif
        } else {
            self.showCompleted = UserDefaults.standard.bool(forKey: key)
        }
    }

    // MARK: - Computed

    var groupedItems: [(category: ItemCategory, items: [ShoppingItem])] {
        ItemCategory.allCases
            .sorted { $0.aisleOrder < $1.aisleOrder }
            .compactMap { cat in
                let bucket = items
                    .filter { item in
                        !item.checked
                            || pendingCompleteIDs.contains(item.id)
                            || showCompleted
                    }
                    .filter { $0.category == cat }
                    .sorted { a, b in
                        let aVis = a.checked || pendingCompleteIDs.contains(a.id)
                        let bVis = b.checked || pendingCompleteIDs.contains(b.id)
                        if aVis != bVis { return !aVis }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                return bucket.isEmpty ? nil : (category: cat, items: bucket)
            }
    }

    var uncheckedCount: Int {
        items.filter { !$0.checked && !pendingCompleteIDs.contains($0.id) }.count
    }
    var checkedCount: Int { items.filter { $0.checked }.count }

    var allKnownNames: [String] {
        let fromItems = items.map(\.name)
        let fromHistory = (UserDefaults.standard.array(forKey: "item_name_history") as? [String]) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for name in fromItems + fromHistory {
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    // MARK: - Lifecycle

    func load(householdId: String) async {
        self.householdId = householdId

        realtime.onEvent = { [weak self] action, record in
            Task { await self?.applyEvent(action: action, record: record) }
        }
        realtime.onReconnect = { [weak self] in
            Task { await self?.fetch() }
        }

        realtime.connect(householdId: householdId)
        await fetch()
    }

    func fetch() async {
        guard let householdId else { return }
        isLoading = true
        do {
            items = try await api.fetchItems(householdId: householdId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Realtime event application

    private func applyEvent(action: String, record: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let item = try? JSONDecoder().decode(ShoppingItem.self, from: data)
        else {
            await fetch()
            return
        }
        guard item.householdId == householdId else { return }

        switch action {
        case "create":
            if !items.contains(where: { $0.id == item.id }) {
                items.append(item)
            }

        case "update":
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
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

    // MARK: - Add

    func addItem(name: String, quantity: String? = nil, notes: String? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let householdId else { return }

        recordInHistory(trimmed)

        // Pre-generate a UUID so the optimistic placeholder and the server record
        // share the same id — the realtime "create" event finds it and skips insert.
        let itemId = UUID().uuidString.lowercased()
        let placeholder = ShoppingItem(
            id:          itemId,
            name:        trimmed,
            quantity:    quantity,
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
                quantity:    quantity,
                notes:       notes
            )
            // Server response includes the categorised item synchronously.
            if let idx = items.firstIndex(where: { $0.id == itemId }) {
                items[idx] = serverItem
            } else if !items.contains(where: { $0.id == serverItem.id }) {
                items.append(serverItem)
            }
        } catch {
            items.removeAll { $0.id == itemId }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Complete / Undo (3-second window)

    func pendingToggle(_ item: ShoppingItem) {
        if pendingCompleteIDs.contains(item.id) {
            pendingTasks[item.id]?.cancel()
            pendingTasks.removeValue(forKey: item.id)
            pendingCompleteIDs.remove(item.id)
        } else if item.checked {
            Task { await uncompleteItem(item) }
        } else {
            pendingCompleteIDs.insert(item.id)
            let itemID = item.id
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    self.pendingCompleteIDs.remove(itemID)
                    self.pendingTasks.removeValue(forKey: itemID)
                    return
                }
                await self.finalizeComplete(id: itemID)
            }
            pendingTasks[item.id] = task
        }
    }

    private func finalizeComplete(id: String) async {
        pendingCompleteIDs.remove(id)
        pendingTasks.removeValue(forKey: id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].checked = true
        _ = try? await api.patchItem(id: id, fields: ["checked": true])
    }

    private func uncompleteItem(_ item: ShoppingItem) async {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].checked = false
        }
        _ = try? await api.patchItem(id: item.id, fields: ["checked": false])
    }

    func toggleItem(_ item: ShoppingItem) async {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].checked.toggle()
        do {
            let updated = try await api.patchItem(id: item.id, fields: ["checked": !item.checked])
            items[idx] = updated
        } catch {
            items[idx].checked = item.checked
            self.error = error.localizedDescription
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

    // MARK: - Delete

    func deleteItem(_ item: ShoppingItem) async {
        pendingTasks[item.id]?.cancel()
        pendingTasks.removeValue(forKey: item.id)
        pendingCompleteIDs.remove(item.id)

        items.removeAll { $0.id == item.id }
        do {
            try await api.deleteItem(id: item.id)
        } catch {
            items.append(item)
            self.error = error.localizedDescription
        }
    }

    func clearChecked() async {
        for id in pendingCompleteIDs { pendingTasks[id]?.cancel() }
        pendingCompleteIDs.removeAll()
        pendingTasks.removeAll()

        let toDelete = items.filter { $0.checked }
        items.removeAll { $0.checked }
        await withTaskGroup(of: Void.self) { group in
            for item in toDelete {
                group.addTask { try? await self.api.deleteItem(id: item.id) }
            }
        }
    }

    // MARK: - History

    private func recordInHistory(_ name: String) {
        var history = (UserDefaults.standard.array(forKey: "item_name_history") as? [String]) ?? []
        history.removeAll { $0.lowercased() == name.lowercased() }
        history.insert(name, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.standard.set(history, forKey: "item_name_history")
    }
}
