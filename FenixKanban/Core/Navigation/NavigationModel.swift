import CoreData
import Observation

/// Holds the currently-selected board and card. Mutated by App Intents
/// (via `@Dependency`) and observed by `ContentView`.
@Observable
@MainActor
final class NavigationModel {
    var selectedBoardID: NSManagedObjectID?
    var selectedCardID: NSManagedObjectID?

    /// Look up a `Board` by its UUID `id` attribute and select it. Returns
    /// `true` when a match is found, `false` otherwise (state is left
    /// unchanged when not found, so a stale UUID doesn't clear navigation).
    @discardableResult
    func openBoard(uuid: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let board = try? context.fetch(request).first else {
            return false
        }
        selectedBoardID = board.objectID
        return true
    }

    @discardableResult
    func openCard(uuid: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let card = try? context.fetch(request).first else {
            return false
        }
        selectedCardID = card.objectID
        return true
    }
}
