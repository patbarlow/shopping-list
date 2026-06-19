import Foundation

// Response from /v1/recipes/parse-url or /v1/recipes/parse-image
struct ParsedRecipeResponse: Decodable {
    let recipeName: String
    let defaultServings: Int?
    let ingredients: [ParsedIngredientResponse]

    enum CodingKeys: String, CodingKey {
        case recipeName      = "recipe_name"
        case defaultServings = "default_servings"
        case ingredients
    }
}

struct ParsedIngredientResponse: Decodable {
    let name: String
    let quantity: String?
    let category: String
    let aisleOrder: Int
    let existingItemId: String?
    let existingQuantity: String?

    enum CodingKeys: String, CodingKey {
        case name, quantity, category
        case aisleOrder       = "aisle_order"
        case existingItemId   = "existing_item_id"
        case existingQuantity = "existing_quantity"
    }
}

// Mutable working copy used during the preview/edit phase
struct EditableIngredient: Identifiable {
    let id = UUID()
    var name: String
    var originalQuantity: String?   // from parse (unscaled)
    var currentQuantity: String?    // displayed (scaled or user-overridden)
    var userEditedQty: Bool = false // when true, scaling won't touch currentQuantity
    var category: String
    var aisleOrder: Int
    var isIncluded: Bool = true
    var existingItemId: String?     // shopping_items.id of matched list entry (server-resolved)
    var existingListQty: String?    // display qty of the existing list item

    init(from response: ParsedIngredientResponse) {
        self.name             = response.name
        self.originalQuantity = response.quantity
        self.currentQuantity  = response.quantity
        self.category         = response.category
        self.aisleOrder       = response.aisleOrder
        self.existingItemId   = response.existingItemId
        self.existingListQty  = response.existingQuantity
        // Pre-exclude items the server confirmed are already on the list
        self.isIncluded       = response.existingItemId == nil
    }

    mutating func applyServingsScale(factor: Double) {
        guard !userEditedQty else { return }
        currentQuantity = EditableIngredient.scaleQuantity(originalQuantity, by: factor)
    }

    static func scaleQuantity(_ raw: String?, by factor: Double) -> String? {
        guard let raw, !raw.isEmpty, factor != 1.0 else { return raw }
        let pattern = #"^(\d+(?:\.\d+)?(?:\s+\d+\/\d+)?|(?:\d+\/\d+))\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let numRange = Range(match.range(at: 1), in: raw),
              let restRange = Range(match.range(at: 2), in: raw)
        else { return raw }

        let numStr = String(raw[numRange]).trimmingCharacters(in: .whitespaces)
        let rest   = String(raw[restRange]).trimmingCharacters(in: .whitespaces)

        let value: Double
        let slashParts = numStr.components(separatedBy: "/")
        let spaceParts  = numStr.components(separatedBy: " ")
        if slashParts.count == 2,
           let num = Double(slashParts[0].trimmingCharacters(in: .whitespaces)),
           let den = Double(slashParts[1].trimmingCharacters(in: .whitespaces)), den != 0 {
            value = (num / den) * factor
        } else if spaceParts.count == 2,
                  let whole = Double(spaceParts[0]),
                  let fracSlash = spaceParts[1].components(separatedBy: "/") as [String]?,
                  fracSlash.count == 2,
                  let num = Double(fracSlash[0]),
                  let den = Double(fracSlash[1]), den != 0 {
            value = (whole + num / den) * factor
        } else if let v = Double(numStr) {
            value = v * factor
        } else {
            return raw
        }

        let formatted: String
        let rounded = value.rounded()
        if abs(value - rounded) < 0.08 {
            formatted = "\(Int(rounded))"
        } else {
            formatted = String(format: "%.1f", value)
        }

        return rest.isEmpty ? formatted : "\(formatted) \(rest)"
    }

    /// Combine an existing list quantity with a recipe quantity.
    /// Adds the leading numbers when units match; falls back to "A + B" if units differ or
    /// either string can't be parsed as a number.
    static func mergeQuantities(_ existing: String?, _ adding: String?) -> String? {
        let a = existing?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = adding?.trimmingCharacters(in: .whitespaces) ?? ""
        if a.isEmpty { return b.isEmpty ? nil : b }
        if b.isEmpty { return a }

        guard let (numA, unitA) = parseLeadingNumber(a),
              let (numB, unitB) = parseLeadingNumber(b),
              unitA.lowercased() == unitB.lowercased()
        else { return "\(a) + \(b)" }

        let sum = numA + numB
        let numStr = abs(sum - sum.rounded()) < 0.05 ? "\(Int(sum.rounded()))" : String(format: "%.1f", sum)
        return unitA.isEmpty ? numStr : "\(numStr) \(unitA)"
    }

    private static func parseLeadingNumber(_ s: String) -> (Double, String)? {
        let patterns: [(String, (NSTextCheckingResult, String) -> (Double, String)?)] = [
            // mixed: "1 1/2 cup"
            (#"^(\d+)\s+(\d+)/(\d+)\s*(.*)"#, { m, s in
                guard let wr = Range(m.range(at: 1), in: s), let nr = Range(m.range(at: 2), in: s),
                      let dr = Range(m.range(at: 3), in: s), let rr = Range(m.range(at: 4), in: s),
                      let w = Double(s[wr]), let n = Double(s[nr]), let d = Double(s[dr]), d != 0
                else { return nil }
                return (w + n / d, String(s[rr]).trimmingCharacters(in: .whitespaces))
            }),
            // fraction: "1/2 cup"
            (#"^(\d+)/(\d+)\s*(.*)"#, { m, s in
                guard let nr = Range(m.range(at: 1), in: s), let dr = Range(m.range(at: 2), in: s),
                      let rr = Range(m.range(at: 3), in: s),
                      let n = Double(s[nr]), let d = Double(s[dr]), d != 0
                else { return nil }
                return (n / d, String(s[rr]).trimmingCharacters(in: .whitespaces))
            }),
            // decimal/integer: "500g" or "2 onions"
            (#"^(\d+(?:\.\d+)?)\s*(.*)"#, { m, s in
                guard let nr = Range(m.range(at: 1), in: s), let rr = Range(m.range(at: 2), in: s),
                      let n = Double(s[nr])
                else { return nil }
                return (n, String(s[rr]).trimmingCharacters(in: .whitespaces))
            }),
        ]
        for (pattern, extract) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let result = extract(m, s) {
                return result
            }
        }
        return nil
    }
}

// Receipt scanning models
struct ReceiptScanResponse: Decodable {
    let storeName: String?
    let totalAmount: Double?
    let matches: [ReceiptMatchResponse]
    let unmatched: [ReceiptLineItemResponse]

    enum CodingKeys: String, CodingKey {
        case storeName    = "store_name"
        case totalAmount  = "total_amount"
        case matches, unmatched
    }
}

struct ReceiptMatchResponse: Decodable, Identifiable {
    var id: String { purchaseHistoryId }
    let receiptItem: ReceiptLineItemResponse
    let purchaseHistoryId: String
    let productName: String

    enum CodingKeys: String, CodingKey {
        case receiptItem      = "receipt_item"
        case purchaseHistoryId = "purchase_history_id"
        case productName      = "product_name"
    }
}

struct ReceiptLineItemResponse: Decodable, Identifiable {
    var id: String { description }
    let description: String
    let quantity: Double?
    let unitPrice: Double?
    let totalPrice: Double?

    enum CodingKeys: String, CodingKey {
        case description, quantity
        case unitPrice  = "unit_price"
        case totalPrice = "total_price"
    }
}

// Mutable working copy for the receipt review screen
struct EditableReceiptMatch: Identifiable {
    let id: String
    let receiptDescription: String
    let productName: String
    let purchaseHistoryId: String
    var priceText: String
    var isIncluded: Bool = true

    init(from response: ReceiptMatchResponse) {
        self.id                 = response.purchaseHistoryId
        self.receiptDescription = response.receiptItem.description
        self.productName        = response.productName
        self.purchaseHistoryId  = response.purchaseHistoryId
        let price = response.receiptItem.totalPrice ?? response.receiptItem.unitPrice
        self.priceText          = price.map { String(format: "%.2f", $0) } ?? ""
    }
}
