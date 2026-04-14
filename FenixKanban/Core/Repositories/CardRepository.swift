import CoreData

protocol CardRepositoryProtocol {
    func fetchCards(in column: Column) -> [Card]
    func fetchAllCards(in board: Board) -> [Card]
    func fetchCardsWithDueDate() -> [Card]
    func createCard(in column: Column, title: String) -> Card
    func updateCard(_ card: Card, title: String?, description: String?, dueDate: Date?, isCompleted: Bool?, label: Label?)
    func deleteCard(_ card: Card)
    func moveCard(_ card: Card, to column: Column, at index: Int)
    func reorderCard(_ card: Card, to newIndex: Int, in cards: [Card])
    func moveCardUp(_ card: Card)
    func moveCardDown(_ card: Card)
}

final class CardRepository: CardRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchCards(in column: Column) -> [Card] {
        return column.sortedCards
    }

    func fetchAllCards(in board: Board) -> [Card] {
        board.sortedColumns.flatMap { $0.sortedCards }
    }

    func fetchCardsWithDueDate() -> [Card] {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "dueDate != nil AND isCompleted == NO")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Card.dueDate, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createCard(in column: Column, title: String) -> Card {
        let card = Card(context: context)
        card.id = UUID()
        card.title = title
        card.createdAt = Date()
        card.modifiedAt = Date()
        card.isCompleted = false
        card.column = column

        let maxSort = column.sortedCards.last?.sortOrder ?? -1000
        card.sortOrder = maxSort + 1000

        column.modifiedAt = Date()
        save()
        return card
    }

    func updateCard(_ card: Card, title: String? = nil, description: String? = nil, dueDate: Date? = nil, isCompleted: Bool? = nil, label: Label? = nil) {
        if let title = title { card.title = title }
        if let description = description { card.cardDescription = description }
        if let dueDate = dueDate { card.dueDate = dueDate }
        if let isCompleted = isCompleted { card.isCompleted = isCompleted }
        // Label can be explicitly set to nil to remove it
        card.label = label
        card.modifiedAt = Date()
        save()
    }

    func clearDueDate(for card: Card) {
        card.dueDate = nil
        card.modifiedAt = Date()
        save()
    }

    func clearLabel(for card: Card) {
        card.label = nil
        card.modifiedAt = Date()
        save()
    }

    func deleteCard(_ card: Card) {
        card.column?.modifiedAt = Date()
        context.delete(card)
        save()
    }

    func moveCard(_ card: Card, to column: Column, at index: Int) {
        card.column?.modifiedAt = Date()
        card.column = column
        column.modifiedAt = Date()

        let targetCards = column.sortedCards.filter { $0.id != card.id }
        let newSortOrder = calculateSortOrder(for: index, in: targetCards.map(\.sortOrder))
        card.sortOrder = newSortOrder
        card.modifiedAt = Date()

        if needsNormalization(targetCards.map(\.sortOrder), inserting: newSortOrder) {
            var ordered = targetCards
            let clampedIndex = min(index, ordered.count)
            ordered.insert(card, at: clampedIndex)
            for (i, c) in ordered.enumerated() {
                c.sortOrder = Int32(i * 1000)
            }
        }

        save()
    }

    func reorderCard(_ card: Card, to newIndex: Int, in cards: [Card]) {
        let sortOrders = cards.map(\.sortOrder)
        let newSortOrder = calculateSortOrder(for: newIndex, in: sortOrders)
        card.sortOrder = newSortOrder
        card.modifiedAt = Date()

        if needsNormalization(sortOrders, inserting: newSortOrder) {
            var ordered = cards.filter { $0.id != card.id }
            let clampedIndex = min(newIndex, ordered.count)
            ordered.insert(card, at: clampedIndex)
            for (i, c) in ordered.enumerated() {
                c.sortOrder = Int32(i * 1000)
            }
        }

        save()
    }

    func moveCardUp(_ card: Card) {
        swapAdjacent(card, offset: -1)
    }

    func moveCardDown(_ card: Card) {
        swapAdjacent(card, offset: 1)
    }

    // Swap this card's sortOrder with the adjacent card at +/- offset.
    // No-op if the adjacent card doesn't exist (card is first/last).
    private func swapAdjacent(_ card: Card, offset: Int) {
        guard let column = card.column else { return }
        let sorted = column.sortedCards
        guard let currentIndex = sorted.firstIndex(where: { $0.objectID == card.objectID }) else { return }
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < sorted.count else { return }

        let other = sorted[targetIndex]
        let tempOrder = card.sortOrder
        card.sortOrder = other.sortOrder
        other.sortOrder = tempOrder

        let now = Date()
        card.modifiedAt = now
        other.modifiedAt = now
        column.modifiedAt = now

        save()
    }

    // MARK: - Sort Order Helpers

    private func calculateSortOrder(for index: Int, in sortOrders: [Int32]) -> Int32 {
        if sortOrders.isEmpty { return 0 }
        if index <= 0 { return sortOrders[0] - 1000 }
        if index >= sortOrders.count { return sortOrders[sortOrders.count - 1] + 1000 }

        let before = sortOrders[index - 1]
        let after = sortOrders[index]
        return before + (after - before) / 2
    }

    private func needsNormalization(_ sortOrders: [Int32], inserting newValue: Int32) -> Bool {
        for existing in sortOrders {
            if existing != newValue && abs(existing - newValue) < 2 {
                return true
            }
        }
        return false
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
