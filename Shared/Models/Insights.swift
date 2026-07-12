import Foundation

// Product insights — only receipt purchases are counted (list checkoffs are excluded server-side).

struct ProductInsight: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String
    let timesPurchased: Int
    let avgPrice: Double?
    let totalSpend: Double?
    let lastPurchasedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category
        case timesPurchased  = "times_purchased"
        case avgPrice        = "avg_price"
        case totalSpend      = "total_spend"
        case lastPurchasedAt = "last_purchased_at"
    }
}

struct ProductInsightsResponse: Decodable {
    let products: [ProductInsight]
}

struct ProductInsightDetail: Decodable {
    let product: ProductRef
    let stats: ProductStats
    let purchases: [ProductPurchase]

    struct ProductRef: Decodable {
        let id: String
        let name: String
        let category: String
    }
}

struct ProductStats: Decodable {
    let timesPurchased: Int
    let avgPrice: Double?
    let totalSpend: Double?
    let minPrice: Double?
    let maxPrice: Double?
    let firstPurchasedAt: String?
    let lastPurchasedAt: String?
    let avgIntervalDays: Int?

    enum CodingKeys: String, CodingKey {
        case timesPurchased   = "times_purchased"
        case avgPrice         = "avg_price"
        case totalSpend       = "total_spend"
        case minPrice         = "min_price"
        case maxPrice         = "max_price"
        case firstPurchasedAt = "first_purchased_at"
        case lastPurchasedAt  = "last_purchased_at"
        case avgIntervalDays  = "avg_interval_days"
    }
}

struct ProductPurchase: Decodable, Identifiable {
    let id: String
    let purchasedAt: String
    let pricePaid: Double?
    let quantity: String?
    let variant: String?
    let storeName: String?

    enum CodingKeys: String, CodingKey {
        case id, quantity, variant
        case purchasedAt = "purchased_at"
        case pricePaid   = "price_paid"
        case storeName   = "store_name"
    }

    /// Date portion ("2026-06-28") used for grouping the purchase log.
    var dayKey: String { String(purchasedAt.prefix(10)) }
}

struct PredictedListResponse: Decodable {
    let range: Range
    let items: [PredictedItem]
    let predictedTotal: Double

    struct Range: Decodable {
        let start: String
        let end: String
    }

    enum CodingKeys: String, CodingKey {
        case range, items
        case predictedTotal = "predicted_total"
    }
}

struct PredictedItem: Decodable, Identifiable {
    let productId: String
    let name: String
    let category: String
    let predictedDate: String
    let predictedPrice: Double?
    let avgIntervalDays: Int
    let timesPurchased: Int
    let lastPurchasedAt: String

    var id: String { productId }

    enum CodingKeys: String, CodingKey {
        case name, category
        case productId       = "product_id"
        case predictedDate    = "predicted_date"
        case predictedPrice   = "predicted_price"
        case avgIntervalDays  = "avg_interval_days"
        case timesPurchased   = "times_purchased"
        case lastPurchasedAt  = "last_purchased_at"
    }
}
