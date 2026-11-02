import Foundation

// Connects to the Worker's SSE endpoint and delivers shopping_items change
// events to the store without requiring a full re-fetch.
//
// Two callbacks:
//   onEvent(action, recordJSON)  — fired for every create / update / delete.
//   onReconnect()               — fired once after each (re)connection so the
//                                  store can do a full fetch to catch any events
//                                  that arrived while disconnected.
@MainActor
final class RealtimeService: ShoppingListRealtime {
    private weak var api: APIService?
    private var streamTask: Task<Void, Never>?

    var onEvent: ((String, [String: Any]) -> Void)?
    var onReconnect: (() -> Void)?

    init(api: APIService) {
        self.api = api
    }

    func connect(householdId: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["TROLLEY_UI_TEST"] == nil else { return }
        #endif
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.stream(householdId: householdId)
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - SSE streaming

    private func stream(householdId: String) async {
        while !Task.isCancelled {
            guard let api,
                  let url = URL(string: "\(api.baseURL)/v1/households/\(householdId)/realtime")
            else { break }

            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let token = api.authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            guard let (byteStream, response) = try? await URLSession.shared.bytes(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            guard !Task.isCancelled else { return }

            // Signal the store to do a full fetch immediately — catches anything
            // missed while the connection was being established.
            onReconnect?()

            do {
                var parser = ServerSentEvents()
                for try await byte in byteStream {
                    guard !Task.isCancelled else { return }
                    if let event = try parser.append(byte) {
                        handle(data: event.data)
                    }
                }
            } catch {
                // Stream ended or errored — fall through to retry
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func handle(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String,
              let record = json["record"] as? [String: Any],
              ["create", "update", "delete"].contains(action)
        else { return }

        onEvent?(action, record)
    }
}
