import AppIntents
import Foundation

struct AddToShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Items to Trolley"
    static var description = IntentDescription("Add one or more items to your Trolley shopping list.")

    // Must be String. A custom type (like the app's ShoppingItem model) is only allowed
    // here if it conforms to AppEntity/AppEnum — which ShoppingItem doesn't, and shouldn't.
    // The intent only needs the spoken text, which parseItems splits into multiple items.
    @Parameter(title: "Item", description: "What to add — say multiple items with 'and' or commas")
    var item: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to Trolley")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = Self.parseItems(item)
        guard !parsed.isEmpty else {
            return .result(dialog: "I didn't catch any items to add.")
        }

        let defaults = UserDefaults(suiteName: "group.com.patbarlow.shoppinglist")
        guard let token       = defaults?.string(forKey: "sl_token"),
              let householdId = defaults?.string(forKey: "sl_household_id") else {
            return .result(dialog: "Please open Trolley and sign in first.")
        }
        let baseURL = defaults?.string(forKey: "sl_base_url")
                      ?? "https://shopping-list-api.pat-barlow.workers.dev"

        // Fetch current list to detect duplicates
        var existingNames: Set<String> = []
        if let url = URL(string: "\(baseURL)/v1/items?household_id=\(householdId)") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let resp = try? JSONDecoder().decode(CurrentListResponse.self, from: data) {
                for i in resp.items where !(i.checked ?? false) {
                    existingNames.insert(i.name.lowercased())
                }
            }
        }

        var alreadyThere: [String] = []
        var added: [String] = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for name in parsed {
                if existingNames.contains(name.lowercased()) {
                    alreadyThere.append(name)
                    continue
                }
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/v1/items") else { return (name, false) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "household_id": householdId, "name": name
                    ])
                    guard let (_, r) = try? await URLSession.shared.data(for: req),
                          let http = r as? HTTPURLResponse,
                          (200...299).contains(http.statusCode)
                    else { return (name, false) }
                    return (name, true)
                }
            }
            for await (name, ok) in group where ok { added.append(name) }
        }

        if !added.isEmpty && !alreadyThere.isEmpty {
            let already = alreadyThere.count == 1
                ? "\(alreadyThere[0]) was already there"
                : "\(Self.formatList(alreadyThere)) were already there"
            return .result(dialog: "Added \(Self.formatList(added)) to Trolley. \(already).")
        } else if added.isEmpty && !alreadyThere.isEmpty {
            let verb = alreadyThere.count == 1 ? "is" : "are"
            return .result(dialog: "\(Self.formatList(alreadyThere)) \(verb) already on your list.")
        } else if !added.isEmpty {
            return .result(dialog: "Added \(Self.formatList(added)) to Trolley.")
        } else {
            return .result(dialog: "Something went wrong — couldn't add those items right now.")
        }
    }

    static func parseItems(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ",")
            .components(separatedBy: ",")
            .map    { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func formatList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

private struct CurrentListResponse: Decodable {
    struct Item: Decodable { let name: String; let checked: Bool? }
    let items: [Item]
}

