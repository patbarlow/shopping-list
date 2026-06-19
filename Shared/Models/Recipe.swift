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

    enum CodingKeys: String, CodingKey {
        case name, quantity, category
        case aisleOrder = "aisle_order"
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
    var existingListQty: String?    // non-nil when already on the shopping list

    init(from response: ParsedIngredientResponse) {
        self.name             = response.name
        self.originalQuantity = response.quantity
        self.currentQuantity  = response.quantity
        self.category         = response.category
        self.aisleOrder       = response.aisleOrder
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
