// FenixKanban/Features/Intents/AddCardIntent.swift
import AppIntents
import CoreData

struct AddCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Card"
    static var description = IntentDescription(
        "Creates a new card in FenixKanban with the given title, placed in the specified board and column."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Title") var title: String
    @Parameter(title: "Board") var board: BoardEntity
    @Parameter(
        title: "Column",
        description: "Name of the column to add the card to. Defaults to the first column.",
        default: nil
    )
    var columnName: String?

    // Test seam — injected by tests, resolved via @Dependency at runtime.
    var contextOverride: NSManagedObjectContext?

    @Dependency private var context: NSManagedObjectContext

    private var resolvedContext: NSManagedObjectContext {
        contextOverride ?? context
    }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<CardEntity> {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $title.needsValueError("Please provide a title for the card.")
        }

        let boardID = board.id
        let targetColumnName = columnName
        let ctx = resolvedContext

        let newCard: Card = try await ctx.perform {
            // Resolve the board
            let boardRequest = Board.fetchRequest()
            boardRequest.predicate = NSPredicate(format: "id == %@", boardID as CVarArg)
            boardRequest.fetchLimit = 1
            guard let foundBoard = try ctx.fetch(boardRequest).first else {
                throw $board.needsValueError("That board no longer exists.")
            }

            // Resolve the target column: named match first, fall back to first by sortOrder
            let columns = foundBoard.sortedColumns
            guard !columns.isEmpty else {
                throw $board.needsValueError("That board has no columns.")
            }

            let targetColumn: Column
            if let name = targetColumnName,
               let match = columns.first(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }) {
                targetColumn = match
            } else {
                targetColumn = columns[0]
            }

            // Create the card
            let card = Card(context: ctx)
            card.id = UUID()
            card.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            card.createdAt = Date()
            card.modifiedAt = Date()
            card.isCompleted = false
            card.column = targetColumn

            let maxSort = targetColumn.sortedCards.last?.sortOrder ?? -1000
            card.sortOrder = maxSort + 1000

            let now = Date()
            targetColumn.modifiedAt = now
            targetColumn.board?.modifiedAt = now

            try ctx.save()
            return card
        }

        let entity = try CardEntity(from: newCard)
        let dialog = IntentDialog("Added \"\(entity.title)\" to \(board.name).")
        return .result(value: entity, dialog: dialog)
    }
}
