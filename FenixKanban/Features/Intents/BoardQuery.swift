import AppIntents
import CoreData

/// EntityQuery resolves `BoardEntity` values from Core Data — used by
/// Shortcuts pickers, Siri parameter resolution, and intent execution.
struct BoardQuery: EntityQuery {
    private let context: NSManagedObjectContext

    /// Default initializer used by App Intents at runtime. Falls back to
    /// `PersistenceController.shared.container.viewContext`.
    init() {
        self.context = PersistenceController.shared.container.viewContext
    }

    /// Test-only initializer — pass an in-memory context.
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func entities(for identifiers: [UUID]) async throws -> [BoardEntity] {
        try await context.perform {
            let request = Board.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", identifiers)
            let boards = try context.fetch(request)
            return boards.compactMap { try? BoardEntity(from: $0) }
        }
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        try await context.perform {
            let request = Board.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            let boards = try context.fetch(request)
            return boards.compactMap { try? BoardEntity(from: $0) }
        }
    }
}
