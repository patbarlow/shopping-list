import AppIntents

// Thin AppEntity wrapping a spoken item name.
// EntityStringQuery lets Siri accept any arbitrary speech input —
// the spoken text is passed straight through as the entity id.
struct ShoppingItem: AppEntity {
    var id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Shopping Item"
    static var defaultQuery = ShoppingItemQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct ShoppingItemQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShoppingItem] {
        identifiers.map { ShoppingItem(id: $0) }
    }

    func entities(matching string: String) async throws -> [ShoppingItem] {
        [ShoppingItem(id: string)]
    }

    func suggestedEntities() async throws -> [ShoppingItem] { [] }
}
