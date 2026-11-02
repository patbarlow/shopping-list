import Foundation
import Testing

@MainActor
private final class SyncAPI: ShoppingListAPI {
    var currentUser: User? { nil }
    var serverItems: [ShoppingItem] = []
    var calls: [String] = []
    var completeGate: CheckedContinuation<Void, Error>?
    var holdCompletion = false
    var failCompletion = false
    var heldFetch: CheckedContinuation<[ShoppingItem], Error>?
    var holdFetch = false

    func fetchItems(householdId: String) async throws -> [ShoppingItem] {
        if holdFetch {
            holdFetch = false
            return try await withCheckedThrowingContinuation { heldFetch = $0 }
        }
        return serverItems
    }
    func completeItem(id: String) async throws {
        calls.append("complete:\(id)")
        if holdCompletion {
            try await withCheckedThrowingContinuation { completeGate = $0 }
        }
        if failCompletion { throw URLError(.notConnectedToInternet) }
        serverItems.removeAll { $0.id == id }
    }
    func undoCompleteItem(id: String) async throws -> ShoppingItem {
        calls.append("undo:\(id)")
        let item = try JSONDecoder().decode(ShoppingItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "name": id, "household_id": "home", "updated_at": "2026-11-01T00:00:03Z",
        ]))
        serverItems.append(item)
        return item
    }
    func createItem(id: String?, householdId: String, name: String, quantity: String?, notes: String?) async throws -> ShoppingItem { fatalError("unused") }
    func createBulkItems(householdId: String, items: [[String: Any]]) async throws -> [ShoppingItem] { fatalError("unused") }
    func patchItem(id: String, fields: [String: Any]) async throws -> ShoppingItem { fatalError("unused") }
    func deleteItem(id: String) async throws { fatalError("unused") }
}

@MainActor
private final class SyncRealtime: ShoppingListRealtime {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onReconnect: (() -> Void)?
    func connect(householdId: String) {}
    func emit(_ action: String, _ item: ShoppingItem) throws {
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        onEvent?(action, record)
    }
}

@MainActor
struct ShoppingSyncTests {
    static func item(_ id: String = "milk") -> ShoppingItem {
        ShoppingItem(id: id, name: id, quantity: nil, notes: nil, householdId: "home", addedBy: "pat")
    }
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }
    private func setup() async -> (ShoppingListStore, SyncAPI, SyncRealtime) {
        let api = SyncAPI()
        api.serverItems = [Self.item(), Self.item("bread")]
        let realtime = SyncRealtime()
        let store = ShoppingListStore(api: api, realtime: realtime)
        await store.load(householdId: "home")
        return (store, api, realtime)
    }

    @Test func completionStartsWithoutWaitingForUndoWindow() async {
        let (store, api, _) = await setup()
        api.holdCompletion = true
        store.pendingToggle(Self.item())
        await waitFor { api.completeGate != nil }
        #expect(api.calls == ["complete:milk"])
        #expect(store.undoDeadline != nil)
        #expect(store.items.map(\.id) == ["bread"])
        api.completeGate?.resume()
        await waitFor { api.serverItems.count == 1 }
    }

    @Test func undoWaitsForInFlightCompletionAndSurvivesItsEcho() async throws {
        let (store, api, realtime) = await setup()
        api.holdCompletion = true
        store.pendingToggle(Self.item())
        await waitFor { api.completeGate != nil }
        store.undoLastComplete()
        try realtime.emit("delete", Self.item())
        #expect(store.items.contains { $0.id == "milk" })
        #expect(api.calls == ["complete:milk"])
        api.completeGate?.resume()
        await waitFor { api.calls.count == 2 }
        #expect(api.calls == ["complete:milk", "undo:milk"])
        #expect(store.items.filter { $0.id == "milk" }.count == 1)
    }

    @Test func anotherTickIsNotHeldBehindTheFirstItem() async {
        let (store, api, _) = await setup()
        store.pendingToggle(Self.item())
        store.pendingToggle(Self.item("bread"))
        await waitFor { api.calls.count == 2 }
        #expect(Set(api.calls) == ["complete:milk", "complete:bread"])
        #expect(store.items.isEmpty)
    }

    @Test func newerRemoteUndoSurvivesAnInFlightCompletion() async throws {
        let (store, api, realtime) = await setup()
        api.holdCompletion = true
        store.pendingToggle(Self.item())
        await waitFor { api.completeGate != nil }
        realtime.onEvent?("update", ["id": "milk", "name": "Restored on other phone", "household_id": "home", "checked": false, "updated_at": "2026-11-01T00:00:02Z"])
        api.completeGate?.resume()
        await waitFor { store.items.contains { $0.name == "Restored on other phone" } }
    }

    @Test func failedCompletionReturnsTheItemAndReportsError() async {
        let (store, api, _) = await setup()
        api.failCompletion = true
        store.pendingToggle(Self.item())
        await waitFor { store.error != nil }
        #expect(store.items.contains { $0.id == "milk" })
        #expect(store.recentlyCompleted.isEmpty)
        #expect(store.undoDeadline == nil)
    }

    @Test func refreshCannotUndoALiveDeletion() async throws {
        let (store, api, realtime) = await setup()
        let stale = api.serverItems
        api.holdFetch = true
        let fetch = Task { await store.fetch() }
        await waitFor { api.heldFetch != nil }
        api.serverItems.removeAll { $0.id == "milk" }
        try realtime.emit("delete", Self.item())
        api.heldFetch?.resume(returning: stale)
        await fetch.value
        #expect(store.items.map(\.id) == ["bread"])
    }

    @Test func refreshDuringUndoDoesNotHideTheRestoredItem() async {
        let (store, api, _) = await setup()
        api.holdCompletion = true
        store.pendingToggle(Self.item())
        await waitFor { api.completeGate != nil }
        store.undoLastComplete()
        api.serverItems.removeAll { $0.id == "milk" }
        await store.fetch()
        #expect(store.items.contains { $0.id == "milk" })
        api.completeGate?.resume()
        await waitFor { api.calls.count == 2 }
    }

    @Test func wireEventsApplyImmediatelyIncludingLegacyBoolean() async throws {
        let (store, _, realtime) = await setup()
        var parser = ServerSentEvents()
        let wire = ": connected\n\ndata: {\"action\":\"update\",\"record\":{\"id\":\"milk\",\"name\":\"Oat milk\",\"household_id\":\"home\",\"checked\":0}}\n\n"
        for byte in wire.utf8 {
            if let event = try parser.append(byte) {
                let payload = try JSONSerialization.jsonObject(with: event.data) as! [String: Any]
                realtime.onEvent?(payload["action"] as! String, payload["record"] as! [String: Any])
            }
        }
        #expect(store.items.first { $0.id == "milk" }?.name == "Oat milk")
    }

    @Test func ignoresOtherHouseholdsAndOlderEvents() async throws {
        let (store, _, realtime) = await setup()
        realtime.onEvent?("update", ["id": "milk", "name": "New", "household_id": "home", "updated_at": "2026-11-01T00:00:02Z"])
        realtime.onEvent?("delete", ["id": "milk", "name": "Old", "household_id": "home", "updated_at": "2026-11-01T00:00:01Z"])
        realtime.onEvent?("update", ["id": "milk", "name": "Other", "household_id": "elsewhere"])
        #expect(store.items.first { $0.id == "milk" }?.name == "New")
    }
}
