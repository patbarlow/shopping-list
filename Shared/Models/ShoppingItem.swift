import Foundation
import SwiftUI

// Matches the 19-aisle Woolworths layout exactly as spec'd
enum ItemCategory: String, Codable, CaseIterable, Identifiable {
    case freshProduce        = "Fruit & Veg"
    case meatAndSeafood      = "Meat & Seafood"
    case deli                = "Deli"
    case bakery              = "Bakery"
    case dairyAndEggs        = "Dairy & Eggs"
    case frozen              = "Frozen"
    case pantry              = "Pantry"
    case breakfast           = "Breakfast"
    case snacksAndConf       = "Snacks & Confectionery"
    case drinks              = "Drinks"
    case condimentsAndSauces = "Condiments & Sauces"
    case baking              = "Baking"
    case international       = "International"
    case healthAndBeauty     = "Health & Beauty"
    case cleaningAndLaundry  = "Cleaning & Laundry"
    case household           = "Household"
    case pet                 = "Pet"
    case baby                = "Baby"
    case other               = "Other"

    var id: String { rawValue }

    var aisleOrder: Int {
        switch self {
        case .freshProduce:        return 1
        case .meatAndSeafood:      return 2
        case .deli:                return 3
        case .bakery:              return 4
        case .dairyAndEggs:        return 5
        case .frozen:              return 6
        case .pantry:              return 7
        case .breakfast:           return 8
        case .snacksAndConf:       return 9
        case .drinks:              return 10
        case .condimentsAndSauces: return 11
        case .baking:              return 12
        case .international:       return 13
        case .healthAndBeauty:     return 14
        case .cleaningAndLaundry:  return 15
        case .household:           return 16
        case .pet:                 return 17
        case .baby:                return 18
        case .other:               return 19
        }
    }

    var emoji: String {
        switch self {
        case .freshProduce:        return "🥦"
        case .meatAndSeafood:      return "🥩"
        case .deli:                return "🧀"
        case .bakery:              return "🍞"
        case .dairyAndEggs:        return "🥛"
        case .frozen:              return "❄️"
        case .pantry:              return "🥫"
        case .breakfast:           return "🥣"
        case .snacksAndConf:       return "🍿"
        case .drinks:              return "🥤"
        case .condimentsAndSauces: return "🫙"
        case .baking:              return "🧁"
        case .international:       return "🌍"
        case .healthAndBeauty:     return "💊"
        case .cleaningAndLaundry:  return "🧺"
        case .household:           return "🏠"
        case .pet:                 return "🐾"
        case .baby:                return "🍼"
        case .other:               return "🛍️"
        }
    }

    var color: Color {
        switch self {
        case .freshProduce:        return .green
        case .meatAndSeafood:      return .red
        case .deli:                return .orange
        case .bakery:              return Color(red: 0.72, green: 0.45, blue: 0.20)
        case .dairyAndEggs:        return Color(red: 0.95, green: 0.75, blue: 0.10)
        case .frozen:              return .cyan
        case .pantry:              return Color(red: 0.55, green: 0.42, blue: 0.28)
        case .breakfast:           return Color(red: 1.0, green: 0.58, blue: 0.18)
        case .snacksAndConf:       return .purple
        case .drinks:              return .blue
        case .condimentsAndSauces: return Color(red: 0.85, green: 0.30, blue: 0.10)
        case .baking:              return Color(red: 0.82, green: 0.60, blue: 0.30)
        case .international:       return .teal
        case .healthAndBeauty:     return .pink
        case .cleaningAndLaundry:  return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .household:           return .gray
        case .pet:                 return Color(red: 0.58, green: 0.38, blue: 0.18)
        case .baby:                return Color(red: 0.85, green: 0.55, blue: 0.75)
        case .other:               return Color(red: 0.50, green: 0.50, blue: 0.55)
        }
    }

    var sfSymbol: String {
        switch self {
        case .freshProduce:        return "leaf"
        case .meatAndSeafood:      return "fork.knife"
        case .deli:                return "takeoutbag.and.cup.and.straw"
        case .bakery:              return "birthday.cake"
        case .dairyAndEggs:        return "drop"
        case .frozen:              return "snowflake"
        case .pantry:              return "archivebox"
        case .breakfast:           return "sun.horizon"
        case .snacksAndConf:       return "popcorn"
        case .drinks:              return "cup.and.saucer"
        case .condimentsAndSauces: return "wand.and.stars"
        case .baking:              return "rectangle.and.pencil.and.ellipsis"
        case .international:       return "globe.europe.africa"
        case .healthAndBeauty:     return "cross.case"
        case .cleaningAndLaundry:  return "sparkles"
        case .household:           return "house"
        case .pet:                 return "pawprint"
        case .baby:                return "figure.and.child.holdinghands"
        case .other:               return "bag"
        }
    }
}

struct ShoppingItem: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var quantity: String?   // e.g. "250ml", "3 packs" — requires quantity TEXT column in PocketBase
    var notes: String?      // optional note — requires notes TEXT column in PocketBase
    var category: ItemCategory
    var aisleOrder: Int
    var checked: Bool
    let householdId: String
    let addedBy: String
    let created: String

    enum CodingKeys: String, CodingKey {
        case id, name, category, checked, created, quantity, notes
        case aisleOrder   = "aisle_order"
        case householdId  = "household_id"
        case addedBy      = "added_by"
    }

    /// Convenience init for a local optimistic placeholder created before
    /// the PocketBase record exists.  The id should be a pre-generated
    /// PocketBase-format ID (15 lowercase alphanumeric chars) so that the
    /// realtime "create" event — which carries that same id — can be matched
    /// and ignored rather than inserted as a duplicate.
    init(id: String, name: String, quantity: String?, notes: String?,
         householdId: String, addedBy: String) {
        self.id          = id
        self.name        = name
        self.quantity    = quantity
        self.notes       = notes
        self.category    = .other
        self.aisleOrder  = ItemCategory.other.aisleOrder
        self.checked     = false
        self.householdId = householdId
        self.addedBy     = addedBy
        self.created     = ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        quantity    = try c.decodeIfPresent(String.self, forKey: .quantity)
        notes       = try c.decodeIfPresent(String.self, forKey: .notes)
        checked     = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        householdId = try c.decodeIfPresent(String.self, forKey: .householdId) ?? ""
        addedBy     = try c.decodeIfPresent(String.self, forKey: .addedBy) ?? ""
        created     = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        let rawCat  = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        category    = ItemCategory(rawValue: rawCat) ?? .other
        aisleOrder  = try c.decodeIfPresent(Int.self, forKey: .aisleOrder) ?? category.aisleOrder
    }
}
