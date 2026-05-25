import AppIntents
import CoreData

struct CardQuery: EntityQuery {
    private let context: NSManagedObjectContext

    init() {
        self.context = PersistenceController.shared.container.viewContext
    }

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func entities(for identifiers: [UUID]) async throws -> [CardEntity] {
        try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", identifiers)
            let cards = try context.fetch(request)
            return cards.compactMap { try? CardEntity(from: $0) }
        }
    }

    func suggestedEntities() async throws -> [CardEntity] {
        try await context.perform {
            let request = Card.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            let cards = try context.fetch(request)
            return cards.compactMap { try? CardEntity(from: $0) }
        }
    }
}
