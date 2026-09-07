import Foundation
import Testing

struct ReceiptTests {
    private func scannedLine() throws -> ReceiptScanItem {
        try JSONDecoder().decode(ReceiptScanItem.self, from: Data(#"{"description":"Milk 2L","quantity":2,"unit_price":3.5,"total_price":7,"product_name":"Milk","is_new":true}"#.utf8))
    }

    @Test func duplicateDescriptionsRemainIndependentlyEditable() throws {
        let line = try scannedLine()
        var first = EditableReceiptItem(from: line)
        let second = EditableReceiptItem(from: line)
        first.isIncluded = false
        first.priceText = "6.00"
        #expect(first.id != second.id)
        #expect(second.isIncluded)
        #expect(second.priceText == "7.00")
    }

    @Test func reviewedPaperPreservesCorrectionsAndExclusions() throws {
        var item = EditableReceiptItem(from: try scannedLine())
        item.quantity = 3
        item.priceText = "10,50"
        item.productName = "Full cream milk"
        item.productId = "existing-milk"
        item.isIncluded = false
        let paper = ReceiptPrintedLine(reviewed: item)
        #expect(paper.quantity == 3)
        #expect(paper.totalPrice == 10.5)
        #expect(paper.productName == "Full cream milk")
        #expect(!paper.isIncluded)
        #expect(!paper.isNew)
    }

    @Test func malformedAndUnknownStreamEventsAreIgnored() {
        let decoder = JSONDecoder()
        #expect(ReceiptScanEvent.decode(event: "item", data: Data("bad json".utf8), using: decoder) == nil)
        #expect(ReceiptScanEvent.decode(event: "future-event", data: Data("{}".utf8), using: decoder) == nil)
    }

    @MainActor @Test func queuedLinesFinishBeforeTotalAndReviewSync() async throws {
        let printer = ReceiptPrinter(interval: .milliseconds(1))
        let first = ReceiptPrintedLine(description: "Milk", quantity: 1, unitPrice: 3.5, totalPrice: 3.5)
        let second = ReceiptPrintedLine(description: "Bread", quantity: 1, unitPrice: 4, totalPrice: 4)
        printer.print(first)
        printer.print(second)
        printer.setTotal(7.5)
        await printer.finish()
        #expect(printer.lines.map(\.description) == ["Milk", "Bread"])
        #expect(printer.totalPrinted)
        #expect(printer.totalAmount == 7.5)
        var reviewed = EditableReceiptItem(from: try scannedLine())
        reviewed.isIncluded = false
        printer.sync(with: [reviewed])
        #expect(printer.lines.count == 1)
        #expect(printer.lines.first?.isIncluded == false)
    }
}
