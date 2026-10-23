import Foundation

/// Decode bytes directly: URLSession.AsyncBytes.lines discards empty SSE delimiters.
struct ServerSentEvents {
    struct Event: Equatable { let name: String; let data: Data }
    private var line: [UInt8] = []
    private var name = ""
    private var payload: [String] = []
    private var previousWasCR = false

    mutating func append(_ byte: UInt8) throws -> Event? {
        if byte == 10, previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        guard byte == 10 || byte == 13 else {
            guard line.count < 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
            line.append(byte)
            return nil
        }
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            defer { name = ""; payload.removeAll(keepingCapacity: true) }
            guard !payload.isEmpty else { return nil }
            return Event(name: name.isEmpty ? "message" : name, data: Data(payload.joined(separator: "\n").utf8))
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var content = parts.count > 1 ? String(parts[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch parts[0] {
        case "event": name = content
        case "data":
            guard payload.reduce(0, { $0 + $1.utf8.count }) + content.utf8.count < 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
            payload.append(content)
        default: break
        }
        return nil
    }
}
