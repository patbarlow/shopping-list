import Foundation

struct User: Codable, Equatable {
    let id: String
    let email: String
    let name: String?
}

struct Household: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let inviteCode: String
    let shoppingFrequency: ShoppingFrequency

    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
        case shoppingFrequency = "shopping_frequency"
    }
}

/// How often the household does a big shop — used to size the forecast
/// horizon instead of assuming everyone shops weekly.
enum ShoppingFrequency: String, Codable, CaseIterable, Identifiable {
    case twiceWeekly  = "twice_weekly"
    case weekly       = "weekly"
    case biweekly     = "biweekly"
    case monthly      = "monthly"
    case twiceMonthly = "twice_monthly"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twiceWeekly:  "Twice a week"
        case .weekly:       "Once a week"
        case .biweekly:     "Once every 2 weeks"
        case .twiceMonthly: "Twice a month"
        case .monthly:      "Once a month"
        }
    }

    /// Days between big shops — mirrors SHOPPING_FREQUENCY_DAYS on the server.
    var tripDays: Int {
        switch self {
        case .twiceWeekly:  4
        case .weekly:       7
        case .biweekly:     14
        case .twiceMonthly: 15
        case .monthly:      30
        }
    }
}

struct HouseholdMember: Codable, Identifiable {
    let id: String
    let householdId: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case id
        case householdId = "household_id"
        case userId      = "user_id"
    }
}
