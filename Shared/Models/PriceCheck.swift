import Foundation

struct PriceOffer: Codable, Equatable {
    var name: String
    var price: Double?
    var size: Double?
    var unit: String?
    var question: String?

    var packSizeLabel: String? {
        guard let size, let unit else { return nil }
        if unit == "mL", size >= 1000 { return "\((size / 1000).formatted()) L" }
        if unit == "g", size >= 1000 { return "\((size / 1000).formatted()) kg" }
        return "\(size.formatted()) \(unit)"
    }

    var baseline: (value: Double, unit: String)? {
        guard let price, price.isFinite, price > 0, let size, size.isFinite, size > 0 else { return nil }
        switch unit {
        case "mL": return (price / size * 100, "100mL")
        case "g": return (price / size * 100, "100g")
        case "each": return (price / size, "each")
        default: return nil
        }
    }
}

/// Only compare like units. Unknown pack sizes are never compared as pack prices.
struct PriceComparison {
    let offer: PriceOffer
    let purchases: [ProductPurchase]
    var comparable: [ProductPurchase] {
        guard let baseline = offer.baseline else { return [] }
        return purchases.filter {
            $0.unitPriceUnit == baseline.unit && ($0.unitPrice ?? 0) > 0 && ($0.unitPrice?.isFinite ?? false)
        }.sorted { $0.purchasedAt > $1.purchasedAt }
    }
    var average: Double? {
        let values = comparable.compactMap(\.unitPrice)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var lowest: Double? { comparable.compactMap(\.unitPrice).min() }
    var changeFromLast: Double? {
        guard let last = comparable.first?.unitPrice, let baseline = offer.baseline else { return nil }
        return (baseline.value / last - 1) * 100
    }
}
