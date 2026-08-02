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
    let lastPrice: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, category
        case timesPurchased  = "times_purchased"
        case avgPrice        = "avg_price"
        case totalSpend      = "total_spend"
        case lastPurchasedAt = "last_purchased_at"
        case lastPrice       = "last_price"
    }

    /// Whether the most recent price is meaningfully above/below the running average.
    enum PriceTrend { case up, down }
    var priceTrend: PriceTrend? {
        guard let last = lastPrice, let avg = avgPrice, avg > 0 else { return nil }
        if last >= avg * 1.05 { return .up }
        if last <= avg * 0.95 { return .down }
        return nil
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
    /// Baseline price for comparing pack sizes — value is per `unitPriceUnit` ("100g" or "100mL").
    let unitPrice: Double?
    let unitPriceUnit: String?

    enum CodingKeys: String, CodingKey {
        case id, quantity, variant
        case purchasedAt   = "purchased_at"
        case pricePaid     = "price_paid"
        case storeName     = "store_name"
        case unitPrice     = "unit_price"
        case unitPriceUnit = "unit_price_unit"
    }

    /// Date portion ("2026-06-28") used for grouping the purchase log.
    var dayKey: String { String(purchasedAt.prefix(10)) }
}

// MARK: - Spend trends

struct TripsResponse: Decodable {
    let trips: [ShoppingTrip]
    let categorySpend: [CategorySpend]

    enum CodingKeys: String, CodingKey {
        case trips
        case categorySpend = "category_spend"
    }
}

/// One scanned receipt = one trip to a store.
struct ShoppingTrip: Decodable, Identifiable {
    let id: String
    let date: String            // "2026-07-25"
    let storeName: String?
    let totalAmount: Double?
    let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case id, date
        case storeName   = "store_name"
        case totalAmount = "total_amount"
        case itemCount   = "item_count"
    }

    /// Collapses store branches to a brand ("Woolworths 1649 Marrickville
    /// Metro" → "Woolworths") so colors stay stable across receipts.
    var brand: String {
        guard let first = storeName?.split(separator: " ").first, !first.isEmpty else { return "Other" }
        return String(first).capitalized
    }
}

struct CategorySpend: Decodable {
    let date: String
    let category: String
    let total: Double
}

struct RenameProductResponse: Decodable {
    let product: ProductInsightDetail.ProductRef
    let merged: Bool
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
