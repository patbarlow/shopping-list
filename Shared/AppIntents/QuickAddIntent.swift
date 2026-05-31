import AppIntents
import Foundation

extension Notification.Name {
    static let shoppingListQuickAdd = Notification.Name("com.patbarlow.shoppinglist.quickAdd")
}

// Used by both the main iOS app (AppShortcuts / Siri / Action Button)
// and the Widget extension (ControlWidget button).
// Because openAppWhenRun = true, perform() runs inside the foregrounded app,
// where NotificationCenter delivers the message to the open WindowGroup.
struct QuickAddIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Shopping List"
    static var description                    = IntentDescription("Open the quick-add sheet.")
    static var openAppWhenRun: Bool           = true
    static var isDiscoverable: Bool           = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .shoppingListQuickAdd, object: nil)
        return .result(dialog: "Opening Shopping List…")
    }
}
