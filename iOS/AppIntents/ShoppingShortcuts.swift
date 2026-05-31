import AppIntents

// Registers App Shortcuts so the app appears in:
//  • Siri ("Hey Siri, add milk and eggs to Shopping List")
//  • Shortcuts app
//  • Action Button settings (iPhone 15 Pro / 16 series)
//
// Two shortcuts:
//   1. QuickAddIntent  — opens the in-app quick-add row (needs foreground)
//   2. AddToShoppingListIntent — adds items directly, no app launch required
//
// iOS 17+ supports \(\.$param) interpolation for String parameters in phrases,
// allowing Siri to capture the item names from the spoken sentence.
struct ShoppingListShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {

        // ── Opens quick-add row inside the app ────────────────────────────
        AppShortcut(
            intent: QuickAddIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Quick add to \(.applicationName)",
                "Open my \(.applicationName) list"
            ],
            shortTitle: "Quick Add",
            systemImageName: "cart.badge.plus"
        )

        // ── Adds items directly (Siri, Shortcuts, Action Button) ──────────
        // String parameters can't be interpolated into AppShortcut phrases
        // (only AppEntity / AppEnum are allowed). Siri will prompt
        // "What would you like to add?" and the spoken reply is parsed by
        // AddToShoppingListIntent.parseItems(_:).
        AppShortcut(
            intent: AddToShoppingListIntent(),
            phrases: [
                "Add to my \(.applicationName)",
                "Add to \(.applicationName)",
                "Add items to \(.applicationName)",
                "Add something to \(.applicationName)"
            ],
            shortTitle: "Add Items",
            systemImageName: "plus.circle"
        )
    }
}
