import Foundation

struct HistoryDay: Decodable, Identifiable {
    var id: String { date }
    let date: String       // "2026-06-20"
    let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case date
        case itemCount = "item_count"
    }

    var displayDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    var dayOfWeek: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return "" }
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }
}

struct HistoryItem: Decodable, Identifiable {
    let id: String
    let productName: String
    let quantity: String?
    let category: String
    let aisleOrder: Int
    let purchasedAt: String
    let pricePaid: Double?

    enum CodingKeys: String, CodingKey {
        case id, quantity, category
        case productName = "product_name"
        case aisleOrder  = "aisle_order"
        case purchasedAt = "purchased_at"
        case pricePaid   = "price_paid"
    }
}
