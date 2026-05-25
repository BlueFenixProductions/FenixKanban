import AppIntents
import CoreData
import Foundation

struct CardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    static var defaultQuery = CardQuery()

    var id: UUID
    var title: String
    var cardDescription: String?
    var dueDate: Date?
    var isCompleted: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: UUID, title: String, cardDescription: String?, dueDate: Date?, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.cardDescription = cardDescription
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }

    init(from card: Card) throws {
        guard let id = card.id else {
            throw CardEntityError.missingID
        }
        self.id = id
        self.title = card.title ?? "Untitled Card"
        self.cardDescription = card.cardDescription
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
    }
}

enum CardEntityError: Error {
    case missingID
}
