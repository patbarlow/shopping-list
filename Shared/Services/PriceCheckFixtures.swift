#if DEBUG
import Foundation

/// Deterministic network fixtures used only by the simulator UI test launch.
final class PriceCheckFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        if path.hasSuffix("/receipts/scan/stream") {
            body = "event: store\ndata: {\"store_name\":\"Woolworths\"}\n\nevent: matched\ndata: {\"store_name\":\"Woolworths\",\"total_amount\":7.8,\"items\":[{\"description\":\"Red Bull 4x250ml\",\"quantity\":1,\"total_price\":7.8,\"product_name\":\"Red Bull\",\"is_new\":false}]}\n\n"
        } else if path.hasSuffix("/items") {
            body = #"{"items":[{"id":"bananas","name":"Bananas","quantity":"6","category":"Fruit & Veg","household_id":"fixture"},{"id":"spinach","name":"Baby spinach","quantity":"120 g","category":"Fruit & Veg","household_id":"fixture"},{"id":"milk","name":"Milk","quantity":"2 L","category":"Dairy & Eggs","household_id":"fixture"},{"id":"eggs","name":"Free range eggs","quantity":"12","category":"Dairy & Eggs","household_id":"fixture"},{"id":"bread","name":"Sourdough","category":"Bakery","household_id":"fixture"},{"id":"red-bull","name":"Red Bull","quantity":"4 pack","category":"Drinks","household_id":"fixture"}]}"#
        } else if path.hasSuffix("/trips") {
            body = #"{"trips":[{"id":"trip-1","date":"\#(today)","store_name":"Woolworths","total_amount":113.7,"item_count":20},{"id":"trip-2","date":"\#(today)","store_name":"Coles","total_amount":24.5,"item_count":4}],"category_spend":[{"date":"\#(today)","category":"Fruit & Veg","total":42.3},{"date":"\#(today)","category":"Dairy & Eggs","total":31.1},{"date":"\#(today)","category":"Drinks","total":22.8}]}"#
        } else if path.hasSuffix("/predictions") {
            body = #"{"range":{"start":"\#(today)","end":"\#(today)"},"predicted_total":22.8,"items":[{"product_id":"milk","name":"Milk","category":"Dairy & Eggs","predicted_date":"\#(today)","predicted_price":4.7,"avg_interval_days":7,"times_purchased":8,"last_purchased_at":"\#(today)"},{"product_id":"oats","name":"Rolled oats","category":"Breakfast","predicted_date":"\#(today)","predicted_price":3.5,"avg_interval_days":14,"times_purchased":5,"last_purchased_at":"\#(today)"},{"product_id":"coffee","name":"Coffee beans","category":"Pantry","predicted_date":"\#(today)","predicted_price":14.6,"avg_interval_days":14,"times_purchased":6,"last_purchased_at":"\#(today)"}]}"#
        } else if path.contains("price-check") {
            let input = requestJSON()
            let isFollowUp = (input["text"] as? String)?.contains("What about $7?") == true
            let previous = input["previous"] as? [String: Any]
            if isFollowUp, previous?["name"] as? String == "Red Bull Energy Drink" {
                body = #"{"name":"Red Bull Energy Drink","price":7,"size":1000,"unit":"mL","question":null}"#
            } else {
                body = #"{"name":"Red Bull Energy Drink","price":9.83,"size":1000,"unit":"mL","question":null}"#
            }
        } else if path.hasSuffix("/products/red-bull") {
            body = #"{"product":{"id":"red-bull","name":"Red Bull Energy Drink","category":"Drinks"},"stats":{"times_purchased":1,"avg_price":7.8,"total_spend":7.8},"purchases":[{"id":"receipt-1","purchased_at":"2026-10-17","price_paid":7.8,"variant":"Red Bull Energy Drink 4x250ml","store_name":"Woolworths Marrickville","unit_price":0.78,"unit_price_unit":"100mL"}]}"#
        } else if path.hasSuffix("/products") {
            body = #"{"products":[{"id":"red-bull","name":"Red Bull Energy Drink","category":"Drinks","times_purchased":1,"avg_price":7.8,"total_spend":7.8,"last_purchased_at":"2026-10-17","avg_unit_price":0.78,"avg_unit_price_unit":"100mL"},{"id":"milk","name":"Milk","category":"Dairy","times_purchased":2,"avg_price":4.7}]}"#
        } else { body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": path.hasSuffix("/stream") ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func requestJSON() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    override func stopLoading() {}
}
#endif
