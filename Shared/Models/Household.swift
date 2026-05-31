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

    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
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
