import AppIntents
import Foundation
import ShoppingCore

// MARK: - Add one or more items via Siri / Shortcuts / Action Button

struct AddToShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Items to Shopping List"
    static var description = IntentDescription("Add one or more items to your shopping list. Separate multiple items with commas or \"and\", e.g. \"milk, eggs and flour\".")

    @Parameter(
        title: "Items",
        description: "One or more items, e.g. \"milk, eggs and flour\""
    )
    var items: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = Self.parseItems(items)
        guard !parsed.isEmpty else {
            return .result(dialog: "I didn't catch any items. Try saying something like \"milk, eggs and flour\".")
        }

        guard let token       = UserDefaults.sharedGroup.string(forKey: "sl_token"),
              let householdId = UserDefaults.sharedGroup.string(forKey: "sl_household_id") else {
            return .result(dialog: "Please open Shopping List and sign in first.")
        }
        let baseURL = UserDefaults.sharedGroup.string(forKey: "sl_base_url")
                      ?? APIService.defaultBaseURL

        var successes = [Bool](repeating: false, count: parsed.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, name) in parsed.enumerated() {
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/v1/items") else { return (i, false) }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
                    req.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "household_id": householdId,
                        "name":         name
                    ])

                    guard let (_, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse,
                          (200...299).contains(http.statusCode)
                    else { return (i, false) }

                    return (i, true)
                }
            }
            for await (i, ok) in group { successes[i] = ok }
        }

        let added = zip(parsed, successes).compactMap { name, ok in ok ? name : nil }
        guard !added.isEmpty else {
            return .result(dialog: "Something went wrong — couldn't add any items right now.")
        }

        return .result(dialog: "Added \(Self.formatList(added)) to your shopping list.")
    }

    // MARK: - Parsing

    static func parseItems(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ",")
            .components(separatedBy: ",")
            .map    { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Formatting

    static func formatList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
