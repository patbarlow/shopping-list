import WidgetKit
import SwiftUI
import AppIntents

struct QuickAddControl: ControlWidget {
    static let kind = "com.patbarlow.shoppinglist.quick-add-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: QuickAddIntent()) {
                Label("Add Item", systemImage: "cart.badge.plus")
            }
        }
        .displayName("Add to List")
        .description("Open the quick-add sheet in Shopping List.")
    }
}
