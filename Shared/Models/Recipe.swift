import Foundation

struct SavedRecipe: Decodable, Identifiable {
    let id: String
    let name: String
    let sourceUrl: String?
    let defaultServings: Int?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case sourceUrl       = "source_url"
        case defaultServings = "default_servings"
        case createdAt       = "created_at"
    }
}

struct SavedRecipesResponse: Decodable {
    let recipes: [SavedRecipe]
}

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
    let receiptDate: String?
    /// The "N Items" tally printed on the receipt, when it prints one.
    let itemCount: Int?
    /// The receipt's own arithmetic didn't reconcile (quantities, item tally or
    /// line totals) — the review screen opens up quantity editing when it's set.
    let needsReview: Bool?
    let items: [ReceiptScanItem]

    enum CodingKeys: String, CodingKey {
        case storeName   = "store_name"
        case totalAmount = "total_amount"
        case receiptDate = "receipt_date"
        case itemCount   = "item_count"
        case needsReview = "needs_review"
        case items
    }
}

// One scanned line with its proposed action: link to an existing product, or create a new one.
struct ReceiptScanItem: Decodable, Identifiable {
    var id: String { description }
    let description: String
    let quantity: Double?
    let unitPrice: Double?
    let totalPrice: Double?
    let sizeValue: Double?         // printed package size, e.g. 175 for "175g"
    let sizeUnit: String?          // "g", "kg", "mL", "L"
    let productId: String?        // non-nil → matched an existing product
    let productName: String       // existing name, or a clean simple name for the new product
    let isNew: Bool
    let purchaseHistoryId: String? // non-nil → backfill this already-listed purchase
    /// The server couldn't reconcile this line's printed numbers (a quantity
    /// that multiplied out to nothing on the receipt) — worth a human look.
    let needsReview: Bool?

    enum CodingKeys: String, CodingKey {
        case description, quantity
        case unitPrice          = "unit_price"
        case totalPrice         = "total_price"
        case sizeValue          = "size_value"
        case sizeUnit           = "size_unit"
        case productId          = "product_id"
        case productName        = "product_name"
        case isNew              = "is_new"
        case purchaseHistoryId  = "purchase_history_id"
        case needsReview        = "needs_review"
    }
}

// MARK: - Streaming scan

/// One line as the scan reads it off the receipt, before product matching.
/// This is what prints onto the screen while the scan is still running.
struct ReceiptPrintedLine: Decodable, Equatable {
    let description: String
    let quantity: Double?
    let unitPrice: Double?
    let totalPrice: Double?

    enum CodingKeys: String, CodingKey {
        case description, quantity
        case unitPrice  = "unit_price"
        case totalPrice = "total_price"
    }

    init(description: String, quantity: Double?, unitPrice: Double?, totalPrice: Double?) {
        self.description = description
        self.quantity    = quantity
        self.unitPrice   = unitPrice
        self.totalPrice  = totalPrice
    }

    /// "×2" / "1.017 kg", matching how the receipt itself prints a modifier.
    var quantityText: String? {
        guard let q = quantity, q != 1 else { return nil }
        return q == q.rounded() ? "×\(Int(q))" : String(format: "%g kg", q)
    }
}

/// The scan, delivered as it happens: the store header, then each product as it
/// is read, then the checked lines, then the finished match proposal.
enum ReceiptScanEvent {
    case store(name: String?, date: String?)
    case item(ReceiptPrintedLine)
    case totals(amount: Double?, itemCount: Int?)
    /// The line items after the arithmetic checks — may correct what was printed.
    case revised(lines: [ReceiptPrintedLine], needsReview: Bool)
    case matched(ReceiptScanResponse)
    case failed(String)
}

private struct StoreEventPayload: Decodable {
    let storeName: String?
    let receiptDate: String?
    enum CodingKeys: String, CodingKey {
        case storeName   = "store_name"
        case receiptDate = "receipt_date"
    }
}

private struct TotalsEventPayload: Decodable {
    let totalAmount: Double?
    let itemCount: Int?
    enum CodingKeys: String, CodingKey {
        case totalAmount = "total_amount"
        case itemCount   = "item_count"
    }
}

private struct RevisedEventPayload: Decodable {
    let lineItems: [ReceiptPrintedLine]
    let needsReview: Bool?
    enum CodingKeys: String, CodingKey {
        case lineItems   = "line_items"
        case needsReview = "needs_review"
    }
}

private struct FailedEventPayload: Decodable {
    let error: String?
}

extension ReceiptScanEvent {
    /// Decode one server-sent event. Unknown event names are ignored so the
    /// server can add events without breaking an older build.
    static func decode(event: String, data: Data, using decoder: JSONDecoder) -> ReceiptScanEvent? {
        switch event {
        case "store":
            guard let p = try? decoder.decode(StoreEventPayload.self, from: data) else { return nil }
            return .store(name: p.storeName, date: p.receiptDate)
        case "item":
            guard let line = try? decoder.decode(ReceiptPrintedLine.self, from: data) else { return nil }
            return .item(line)
        case "totals":
            guard let p = try? decoder.decode(TotalsEventPayload.self, from: data) else { return nil }
            return .totals(amount: p.totalAmount, itemCount: p.itemCount)
        case "revised":
            guard let p = try? decoder.decode(RevisedEventPayload.self, from: data) else { return nil }
            return .revised(lines: p.lineItems, needsReview: p.needsReview ?? false)
        case "matched":
            guard let r = try? decoder.decode(ReceiptScanResponse.self, from: data) else { return nil }
            return .matched(r)
        case "failed":
            let p = try? decoder.decode(FailedEventPayload.self, from: data)
            return .failed(p?.error ?? "could_not_parse")
        default:
            return nil
        }
    }
}

// Mutable working copy for the receipt review screen — one row per scanned line.
struct EditableReceiptItem: Identifiable {
    let id: String
    let description: String
    /// Editable: the scan can staple a multi-buy onto the wrong product, and
    /// the quantity divides the price when computing $/100g baselines.
    var quantity: Double?
    var needsReview: Bool
    var priceText: String
    var isIncluded: Bool = true

    // Current resolution. productId == nil means "create a new product named productName".
    var productId: String?
    var productName: String
    var isNew: Bool
    var purchaseHistoryId: String?

    // Carried through to /confirm for the $/100g-style unit price baseline.
    var unitPrice: Double?
    let sizeValue: Double?
    let sizeUnit: String?

    init(from item: ReceiptScanItem) {
        self.id                = item.description
        self.description       = item.description
        self.quantity          = item.quantity
        self.needsReview       = item.needsReview ?? false
        let price              = item.totalPrice ?? item.unitPrice
        self.priceText         = price.map { String(format: "%.2f", $0) } ?? ""
        self.productId         = item.productId
        self.productName       = item.productName
        self.isNew             = item.isNew
        self.purchaseHistoryId = item.purchaseHistoryId
        self.unitPrice         = item.unitPrice
        self.sizeValue         = item.sizeValue
        self.sizeUnit          = item.sizeUnit
    }

    var quantityText: String? {
        guard let q = quantity, q != 1 else { return nil }
        // Whole numbers are unit counts ("×2"); fractional quantities are loose
        // weights, which receipts print in kg ("1.017 kg").
        return q == q.rounded() ? "×\(Int(q))" : String(format: "%g kg", q)
    }

    /// Unit counts can be corrected in the review screen; a weighed quantity
    /// (1.017 kg) is only meaningful as printed, so it stays read-only.
    var isUnitCount: Bool {
        guard let q = quantity else { return true }
        return q == q.rounded() && q >= 1 && q < 100
    }

    /// "×2 @ $1.69" — showing the arithmetic is what makes a wrong multi-buy
    /// obvious at a glance next to the line's price.
    var quantityDetail: String? {
        guard let text = quantityText else { return nil }
        guard let unit = unitPrice, unit > 0 else { return text }
        return String(format: "%@ @ $%.2f", text, unit)
    }
}

// Product search result for the picker sheet
struct ProductSearchResult: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String
}

struct ProductSearchResponse: Decodable {
    let products: [ProductSearchResult]
}

// Result of a product picker selection
enum ProductPickerResult {
    case existing(id: String, name: String)
    case create(name: String)
}
