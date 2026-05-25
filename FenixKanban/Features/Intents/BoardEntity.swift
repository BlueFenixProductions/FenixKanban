import AppIntents
import CoreData

/// App Intents representation of a `Board`. Lets Siri / Shortcuts
/// reference boards by their UUID identifier.
struct BoardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Board")
    }

    static var defaultQuery = BoardQuery()

    var id: UUID
    var name: String
    var colorHex: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String, colorHex: String?) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    /// Convenience initializer from a managed `Board`.
    /// - Throws: `BoardEntityError.missingID` when the board has no UUID.
    init(from board: Board) throws {
        guard let id = board.id else {
            throw BoardEntityError.missingID
        }
        self.id = id
        self.name = board.name ?? "Untitled Board"
        self.colorHex = board.colorHex
    }
}

enum BoardEntityError: Error {
    case missingID
}
