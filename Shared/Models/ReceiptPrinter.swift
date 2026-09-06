import Foundation
import Observation

/// The paper, as the scan feeds it.
///
/// A receipt scan now streams: the store header arrives first, then each product
/// as the model reads it off the receipt. This holds what has been printed so
/// far and paces what arrives, because the two sources run at very different
/// speeds — a photographed receipt trickles in over several seconds, while a
/// PDF's text layer can deliver thirty lines at once, which would flash onto the
/// screen in a single frame instead of printing.
@MainActor
@Observable
final class ReceiptPrinter {
    private(set) var storeName: String?
    private(set) var dateText: String?
    private(set) var lines: [ReceiptPrintedLine] = []
    private(set) var totalAmount: Double?
    /// The total prints last, once every line is on the paper.
    private(set) var totalPrinted = false

    /// Read but not yet printed.
    private var pending: [ReceiptPrintedLine] = []
    private var pump: Task<Void, Never>?
    private let interval: Duration

    init(interval: Duration = .milliseconds(130)) {
        self.interval = interval
    }

    /// A deep queue means the whole receipt landed at once (the PDF path), so
    /// the paper speeds up rather than making someone watch it tick out.
    private var nextInterval: Duration {
        pending.count > 12 ? .milliseconds(55) : interval
    }

    func setStore(name: String?, date: String?) {
        storeName = name
        dateText = Self.formatDate(date)
    }

    /// Queue a line the scan just read.
    func print(_ line: ReceiptPrintedLine) {
        pending.append(line)
        startPump()
    }

    /// Replace what's on the paper with the checked line items.
    ///
    /// The arithmetic checks run once the whole receipt has been read, and they
    /// can correct lines that already printed — a multi-buy moving to the
    /// product it actually belongs to, a discount folding into the items above
    /// it. Printed lines are updated where they changed and the rest is re-queued,
    /// so the correction lands as a visible amendment rather than a silent one.
    func revise(with revised: [ReceiptPrintedLine]) {
        guard !revised.isEmpty else { return }
        let printedCount = lines.count
        lines = Array(revised.prefix(printedCount))
        pending = Array(revised.dropFirst(printedCount))
        if !pending.isEmpty { startPump() }
    }

    func setTotal(_ amount: Double?) {
        totalAmount = amount
    }

    /// Show the reviewed rows on the paper: the product each line will be saved
    /// as, at its edited price and quantity, with excluded lines struck out.
    /// Called once matching has run, and again whenever the edit sheet closes.
    /// Only meaningful once every line has printed — it replaces, not queues.
    func sync(with items: [EditableReceiptItem]) {
        guard pending.isEmpty else { return }
        lines = items.map(ReceiptPrintedLine.init(reviewed:))
    }

    /// Wait for the queue to drain, print the total, and let it settle before
    /// the caller moves on to matching.
    func finish() async {
        while !pending.isEmpty {
            try? await Task.sleep(for: nextInterval)
        }
        totalPrinted = true
        try? await Task.sleep(for: .milliseconds(650))
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.pending.isEmpty else { break }
                self.lines.append(self.pending.removeFirst())
                try? await Task.sleep(for: self.nextInterval)
            }
            self?.pump = nil
        }
    }

    private static func formatDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(raw.prefix(10))) else { return nil }
        let display = DateFormatter()
        display.dateStyle = .full
        display.timeStyle = .none
        return display.string(from: date)
    }
}
