// FenixKanban/Features/Intents/ToggleGoldenIntent.swift
import AppIntents
import CoreData

struct ToggleGoldenIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Golden Ticket"
    static var description = IntentDescription(
        "Marks or unmarks a card as golden — promotes it to the top of its column."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Card") var card: CardEntity

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
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<CardEntity> {
        let id = card.id
        let context = resolvedContext

        let updated: Card = try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let card = try context.fetch(request).first else {
                throw $card.needsValueError("That card no longer exists.")
            }
            card.isGolden.toggle()
            card.modifiedAt = Date()
            card.column?.modifiedAt = Date()
            card.column?.board?.modifiedAt = Date()
            try context.save()
            return card
        }

        let entity = try CardEntity(from: updated)
        let message: LocalizedStringResource = entity.isGolden
            ? "Marked \(entity.title) as the golden ticket."
            : "Removed golden ticket from \(entity.title)."
        let dialog = IntentDialog(message)
        return .result(value: entity, dialog: dialog)
    }
}
