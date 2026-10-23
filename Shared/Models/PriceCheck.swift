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

extension PriceComparison {
    var changeFromAverage: Double? {
        guard let average, let baseline = offer.baseline else { return nil }
        return (baseline.value / average - 1) * 100
    }

    /// Compare frequency at cent precision. A single observation or tied modes
    /// does not establish a usual price. Retain the original values for maths.
    var usual: Double? {
        let values = comparable.compactMap(\.unitPrice)
        let groups = Dictionary(grouping: values) { ($0 * 100).rounded() }
        guard let largest = groups.values.map(\.count).max(), largest > 1 else { return nil }
        let winners = groups.values.filter { $0.count == largest }
        guard winners.count == 1, let winner = winners.first else { return nil }
        return winner.reduce(0, +) / Double(winner.count)
    }

    func priceForOfferPack(_ baseline: Double) -> Double? {
        guard let size = offer.size, offer.baseline != nil else { return nil }
        return baseline * size / (offer.unit == "each" ? 1 : 100)
    }
}

/// Automatic selection is deliberately exact; similar brands or variants are
/// offered as choices, never silently used as the benchmark.
enum PriceProductMatcher {
    static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_AU"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func exactMatch(name: String, products: [ProductInsight]) -> ProductInsight? {
        let matches = products.filter { key($0.name) == key(name) }
        return matches.count == 1 ? matches[0] : nil
    }
}
