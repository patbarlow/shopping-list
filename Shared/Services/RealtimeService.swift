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
final class RealtimeService {
    private weak var api: APIService?
    private var streamTask: Task<Void, Never>?

    var onEvent: ((String, [String: Any]) -> Void)?
    var onReconnect: (() -> Void)?

    init(api: APIService) {
        self.api = api
    }

    func connect(householdId: String) {
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
            if let token = api.authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            guard let (byteStream, _) = try? await URLSession.shared.bytes(for: request) else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            // Signal the store to do a full fetch immediately — catches anything
            // missed while the connection was being established.
            onReconnect?()

            do {
                var pendingData: String?
                for try await line in byteStream.lines {
                    guard !Task.isCancelled else { return }

                    if line.hasPrefix("data:") {
                        pendingData = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    } else if line.isEmpty, let data = pendingData {
                        pendingData = nil
                        handle(data: data)
                    }
                    // Lines starting with ":" are SSE comments (e.g. ": connected") — skip.
                }
            } catch {
                // Stream ended or errored — fall through to retry
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func handle(data: String) {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let action = json["action"] as? String,
              let record = json["record"] as? [String: Any],
              ["create", "update", "delete"].contains(action)
        else { return }

        onEvent?(action, record)
    }
}
