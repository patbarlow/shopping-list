import AppIntents

struct ShoppingItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Shopping Item")
    static let defaultQuery = ShoppingItemEntityQuery()

    var id: String

    init(id: String) { self.id = id }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct ShoppingItemEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShoppingItemEntity] {
        identifiers.map { ShoppingItemEntity(id: $0) }
    }

    func entities(matching string: String) async throws -> [ShoppingItemEntity] {
        [ShoppingItemEntity(id: string)]
    }
}
