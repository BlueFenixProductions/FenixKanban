// FenixKanban/Features/Intents/FindGoldenCardsIntent.swift
import AppIntents
import CoreData

struct FindGoldenCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Golden Cards"
    static var description = IntentDescription(
        "Returns the cards currently marked as golden, optionally scoped to one board."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Board",
        description: "Limit results to one board. Leave empty for all boards.",
        default: nil
    )
    var board: BoardEntity?

    // Optional test seam. Runtime resolves via AppDependencyManager.
    var contextOverride: NSManagedObjectContext?

    @Dependency private var context: NSManagedObjectContext

    private var resolvedContext: NSManagedObjectContext {
        contextOverride ?? context
    }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        let boardID = board?.id
        let context = resolvedContext

        let entities: [CardEntity] = try await context.perform {
            let request = Card.fetchRequest()
            if let boardID {
                request.predicate = NSPredicate(
                    format: "isGolden == YES AND column.board.id == %@",
                    boardID as CVarArg
                )
            } else {
                request.predicate = NSPredicate(format: "isGolden == YES")
            }
            request.sortDescriptors = [
                NSSortDescriptor(key: "modifiedAt", ascending: false)
            ]
            return try context.fetch(request).compactMap { try? CardEntity(from: $0) }
        }
        return .result(value: entities)
    }
}
