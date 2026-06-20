import AppIntents

struct ShoppingListShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {

        // One-shot: "Add milk in Trolley" — item captured inline, no second step.
        // "in" / "using" route to the app reliably; "to" tends to resolve toward
        // Reminders + a list named "Trolley", so keep app name at the end of each phrase.
        AppShortcut(
            intent: AddToShoppingListIntent(),
            phrases: [
                "Add \(\.$item) in \(.applicationName)",
                "Add \(\.$item) to \(.applicationName)",
                "Put \(\.$item) in \(.applicationName)",
                "Add \(\.$item) using \(.applicationName)",
                "\(.applicationName) add \(\.$item)"
            ],
            shortTitle: "Add Item",
            systemImageName: "cart.badge.plus"
        )

        // Fallback: opens the app.
        AppShortcut(
            intent: QuickAddIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show my \(.applicationName)"
            ],
            shortTitle: "Open Trolley",
            systemImageName: "cart"
        )
    }
}

