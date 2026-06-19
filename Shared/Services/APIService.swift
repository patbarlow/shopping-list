import Foundation

@MainActor
final class APIService {
    static let defaultBaseURL = "https://shopping-list-api.pat-barlow.workers.dev"

    var baseURL: String {
        UserDefaults.standard.string(forKey: "sl_base_url") ?? Self.defaultBaseURL
    }

    private(set) var authToken: String?
    private(set) var currentUser: User?

    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    init() {
        authToken   = UserDefaults.standard.string(forKey: "sl_token")
        currentUser = UserDefaults.standard.data(forKey: "sl_user")
            .flatMap { try? decoder.decode(User.self, from: $0) }
    }

    // MARK: - Auth

    func requestCode(email: String) async throws {
        let _: AnyDecodable = try await post(
            "/auth/email/start",
            body: ["email": email],
            authenticated: false
        )
    }

    func verifyCode(email: String, code: String) async throws -> User {
        let response: AuthResponse = try await post(
            "/auth/email/verify",
            body: ["email": email, "code": code],
            authenticated: false
        )
        persist(token: response.session, user: response.user)
        return response.user
    }

    func logout() {
        authToken   = nil
        currentUser = nil
        ["sl_token", "sl_user", "sl_user_id", "sl_household_id"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    // MARK: - Shopping Items

    func fetchItems(householdId: String) async throws -> [ShoppingItem] {
        let response: ItemsResponse = try await get(
            "/v1/items",
            query: ["household_id": householdId]
        )
        return response.items
    }

    func createItem(
        id: String? = nil,
        householdId: String,
        name: String,
        quantity: String? = nil,
        notes: String? = nil
    ) async throws -> ShoppingItem {
        var body: [String: Any] = [
            "household_id": householdId,
            "name": name
        ]
        if let id                       { body["id"]       = id }
        if let q = quantity, !q.isEmpty { body["quantity"] = q }
        if let n = notes,    !n.isEmpty { body["notes"]    = n }
        return try await post("/v1/items", body: body)
    }

    func patchItem(id: String, fields: [String: Any]) async throws -> ShoppingItem {
        return try await patch("/v1/items/\(id)", body: fields)
    }

    func completeItem(id: String) async throws {
        guard let url = URL(string: baseURL + "/v1/items/\(id)/complete") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw APIError.unauthorized }
            if http.statusCode == 404 { throw APIError.notFound }
            if http.statusCode >= 400 { throw APIError.serverError("HTTP \(http.statusCode)") }
        }
    }

    func deleteItem(id: String) async throws {
        try await delete("/v1/items/\(id)")
    }

    func createBulkItems(householdId: String, items: [[String: Any]]) async throws -> [ShoppingItem] {
        let body: [String: Any] = ["household_id": householdId, "items": items]
        let response: BulkItemsResponse = try await post("/v1/items/bulk", body: body)
        return response.items
    }

    // MARK: - Recipes

    func parseRecipeFromURL(householdId: String, url: String) async throws -> ParsedRecipeResponse {
        let body: [String: Any] = ["household_id": householdId, "url": url]
        return try await post("/v1/recipes/parse-url", body: body)
    }

    func parseRecipeFromImage(householdId: String, imageBase64: String, mediaType: String = "image/jpeg") async throws -> ParsedRecipeResponse {
        let body: [String: Any] = ["household_id": householdId, "image_base64": imageBase64, "media_type": mediaType]
        return try await post("/v1/recipes/parse-image", body: body)
    }

    func saveRecipe(householdId: String, name: String, sourceUrl: String?, defaultServings: Int?, ingredients: [[String: Any]]) async throws {
        var body: [String: Any] = ["household_id": householdId, "name": name, "ingredients": ingredients]
        if let url = sourceUrl     { body["source_url"]       = url }
        if let s   = defaultServings { body["default_servings"] = s }
        let _: AnyDecodable = try await post("/v1/recipes/save", body: body)
    }

    // MARK: - Receipts

    func scanReceipt(householdId: String, imageBase64: String, mediaType: String = "image/jpeg") async throws -> ReceiptScanResponse {
        let body: [String: Any] = ["household_id": householdId, "image_base64": imageBase64, "media_type": mediaType]
        return try await post("/v1/receipts/scan", body: body)
    }

    func confirmReceipt(householdId: String, storeName: String?, totalAmount: Double?, matches: [[String: Any]]) async throws {
        var body: [String: Any] = ["household_id": householdId, "matches": matches]
        if let s = storeName    { body["store_name"]    = s }
        if let t = totalAmount  { body["total_amount"]  = t }
        let _: AnyDecodable = try await post("/v1/receipts/confirm", body: body)
    }

    // MARK: - History

    func fetchHistoryDays(householdId: String) async throws -> [HistoryDay] {
        let response: HistoryDaysResponse = try await get(
            "/v1/insights/history/days",
            query: ["household_id": householdId]
        )
        return response.days
    }

    func fetchHistoryDay(householdId: String, date: String) async throws -> [HistoryItem] {
        let response: HistoryDayResponse = try await get(
            "/v1/insights/history/day/\(date)",
            query: ["household_id": householdId]
        )
        return response.items
    }

    // MARK: - Households

    func createHousehold(name: String) async throws -> Household {
        let response: HouseholdResponse = try await post(
            "/v1/households",
            body: ["name": name]
        )
        UserDefaults.standard.set(response.household.id, forKey: "sl_household_id")
        return response.household
    }

    func joinHousehold(inviteCode: String) async throws -> Household {
        let response: HouseholdResponse = try await post(
            "/v1/households/join",
            body: ["invite_code": inviteCode.uppercased()]
        )
        UserDefaults.standard.set(response.household.id, forKey: "sl_household_id")
        return response.household
    }

    func fetchMyHousehold() async throws -> Household? {
        let response: HouseholdNullableResponse = try await get(
            "/v1/households/mine",
            query: [:]
        )
        if let h = response.household {
            UserDefaults.standard.set(h.id, forKey: "sl_household_id")
        }
        return response.household
    }

    // MARK: - HTTP primitives

    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var comps = URLComponents(string: baseURL + path)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await execute(req)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    func delete(_ path: String) async throws {
        guard let url = URL(string: baseURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw APIError.unauthorized }
            if http.statusCode == 404 { throw APIError.notFound }
            if http.statusCode >= 400 { throw APIError.serverError("HTTP \(http.statusCode)") }
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        if http.statusCode >= 400 {
            let msg = (try? decoder.decode(APIErrorResponse.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError.serverError(msg)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.serverError("Decode error: \(error)")
        }
    }

    private func persist(token: String, user: User) {
        authToken   = token
        currentUser = user
        UserDefaults.standard.set(token,             forKey: "sl_token")
        UserDefaults.standard.set(user.id,           forKey: "sl_user_id")
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: "sl_user")
    }
}

// MARK: - Response types

private struct AuthResponse: Decodable {
    let session: String
    let user: User
}

private struct ItemsResponse: Decodable {
    let items: [ShoppingItem]
}

private struct BulkItemsResponse: Decodable {
    let items: [ShoppingItem]
}

private struct HouseholdResponse: Decodable {
    let household: Household
}

private struct HouseholdNullableResponse: Decodable {
    let household: Household?
}

private struct APIErrorResponse: Decodable {
    let error: String
}

// Sink type for fire-and-forget POST responses (e.g. /auth/email/start)
private struct HistoryDaysResponse: Decodable {
    let days: [HistoryDay]
}

private struct HistoryDayResponse: Decodable {
    let date: String
    let items: [HistoryItem]
}

private struct AnyDecodable: Decodable {}

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    case unauthorized
    case notFound
    case serverError(String)
    case networkError(Error)
    case badURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:       return "Not signed in."
        case .notFound:           return "Not found."
        case .serverError(let m): return m
        case .networkError(let e):return e.localizedDescription
        case .badURL:             return "Invalid URL."
        }
    }

    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized), (.notFound, .notFound), (.badURL, .badURL): return true
        case (.serverError(let a), .serverError(let b)): return a == b
        default: return false
        }
    }
}
