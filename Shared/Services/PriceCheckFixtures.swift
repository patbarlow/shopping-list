#if DEBUG
import Foundation

/// Deterministic network fixtures used only by the simulator UI test launch.
final class PriceCheckFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        if path.hasSuffix("/receipts/scan/stream") {
            body = "event: store\ndata: {\"store_name\":\"Woolworths\"}\n\nevent: matched\ndata: {\"store_name\":\"Woolworths\",\"total_amount\":7.8,\"items\":[{\"description\":\"Red Bull 4x250ml\",\"quantity\":1,\"total_price\":7.8,\"product_name\":\"Red Bull\",\"is_new\":false}]}\n\n"
        } else if path.contains("price-check") {
            body = #"{"name":"Red Bull Energy Drink","price":9.83,"size":1000,"unit":"mL","question":null}"#
        } else if path.hasSuffix("/products/red-bull") {
            body = #"{"product":{"id":"red-bull","name":"Red Bull Energy Drink","category":"Drinks"},"stats":{"times_purchased":1,"avg_price":7.8,"total_spend":7.8},"purchases":[{"id":"receipt-1","purchased_at":"2026-10-17","price_paid":7.8,"variant":"Red Bull Energy Drink 4x250ml","store_name":"Woolworths Marrickville","unit_price":0.78,"unit_price_unit":"100mL"}]}"#
        } else if path.hasSuffix("/products") {
            body = #"{"products":[{"id":"red-bull","name":"Red Bull Energy Drink","category":"Drinks","times_purchased":1,"avg_price":7.8,"total_spend":7.8,"last_purchased_at":"2026-10-17","avg_unit_price":0.78,"avg_unit_price_unit":"100mL"},{"id":"milk","name":"Milk","category":"Dairy","times_purchased":2,"avg_price":4.7}]}"#
        } else { body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": path.hasSuffix("/stream") ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
