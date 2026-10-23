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

struct ReceiptStreamRegressionTests {
    @Test func preservesEmptyDelimitersAndUnicode() throws {
        let wire = "event: store\r\ndata: {\"store_name\":\"Café\"}\r\n\r\nevent: matched\ndata: {\"items\": []}\n\n"
        var parser = ServerSentEvents()
        let events = try wire.utf8.compactMap { try parser.append($0) }
        #expect(events.map(\.name) == ["store", "matched"])
        #expect(String(decoding: events[0].data, as: UTF8.self) == #"{"store_name":"Café"}"#)
    }
    @Test func joinsDataLinesAndDoesNotDispatchIncompleteFrames() throws {
        var parser = ServerSentEvents()
        let wire = ": heartbeat\nevent: matched\ndata: {\ndata: \"items\": []}\n\nevent: item\ndata: truncated"
        let events = try wire.utf8.compactMap { try parser.append($0) }
        #expect(events.count == 1)
        #expect(String(decoding: events[0].data, as: UTF8.self) == "{\n\"items\": []}")
    }
}

struct PriceComparisonTests {
    private func purchase(value: Double?, unit: String?) throws -> ProductPurchase {
        let json: [String: Any] = ["id": "receipt-red-bull", "purchased_at": "2026-10-17", "price_paid": 7.8,
            "unit_price": value as Any? ?? NSNull(), "unit_price_unit": unit as Any? ?? NSNull()]
        return try JSONDecoder().decode(ProductPurchase.self, from: JSONSerialization.data(withJSONObject: json))
    }
    @Test func redBullAcceptanceCase() throws {
        let offer = PriceOffer(name: "Red Bull 4 × 250mL", price: 9.83, size: 1000, unit: "mL")
        let comparison = PriceComparison(offer: offer, purchases: [try purchase(value: 0.78, unit: "100mL")])
        #expect(offer.packSizeLabel == "1 L")
        #expect(abs(offer.baseline!.value - 0.983) < 0.00001)
        #expect(abs(comparison.changeFromLast! - 26.025641) < 0.00001)
        #expect(comparison.comparable.count == 1)
    }
    @Test func missingSizesAndDifferentDimensionsNeverCompare() throws {
        let offer = PriceOffer(name: "Red Bull", price: 9.83, size: 1000, unit: "mL")
        let comparison = PriceComparison(offer: offer, purchases: [try purchase(value: nil, unit: nil), try purchase(value: 0.78, unit: "100g")])
        #expect(comparison.changeFromLast == nil)
        #expect(PriceOffer(name: "Unknown", price: 9.83, size: nil, unit: "mL").baseline == nil)
        #expect(PriceOffer(name: "Invalid", price: 9.83, size: 0, unit: "mL").baseline == nil)
    }
}

struct PriceSummaryTests {
    private func purchase(_ value: Double, unit: String = "100mL") throws -> ProductPurchase {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "purchased_at": "2026-10-17", "unit_price": value, "unit_price_unit": unit])
        return try JSONDecoder().decode(ProductPurchase.self, from: data)
    }
    @Test func averageAndModeUseCompatiblePrices() throws {
        let offer = PriceOffer(name: "Red Bull", price: 9.83, size: 1000, unit: "mL")
        let comparison = PriceComparison(offer: offer, purchases: try [purchase(0.78), purchase(0.78), purchase(0.9), purchase(20, unit: "100g")])
        #expect(abs(comparison.average! - 0.82) < 0.00001)
        #expect(comparison.usual == 0.78)
        #expect(abs(comparison.priceForOfferPack(comparison.average!)! - 8.2) < 0.00001)
        #expect(abs(comparison.changeFromAverage! - 19.8780488) < 0.00001)
    }
    @Test func singleOrTiedModeDoesNotInventUsualPrice() throws {
        let offer = PriceOffer(name: "Milk", price: 3, size: 1000, unit: "mL")
        #expect(PriceComparison(offer: offer, purchases: [try purchase(0.3)]).usual == nil)
        #expect(PriceComparison(offer: offer, purchases: try [purchase(0.3), purchase(0.3), purchase(0.4), purchase(0.4)]).usual == nil)
    }
    @Test func exactMatchingKeepsVariantsSeparate() throws {
        let data = Data(#"[{"id":"1","name":"Red Bull Energy Drink","category":"Drinks","times_purchased":1},{"id":"2","name":"Red Bull Sugar Free","category":"Drinks","times_purchased":1}]"#.utf8)
        let products = try JSONDecoder().decode([ProductInsight].self, from: data)
        #expect(PriceProductMatcher.exactMatch(name: "Red Bull Energy Drink", products: products)?.id == "1")
        #expect(PriceProductMatcher.exactMatch(name: "Red Bull", products: products) == nil)
        #expect(PriceProductMatcher.exactMatch(name: "Red Bull Energy Drink", products: products + products) == nil)
    }
}
