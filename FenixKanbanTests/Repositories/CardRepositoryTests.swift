import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card Repository", .serialized)
@MainActor
struct CardRepositoryTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        column = boardRepo.createColumn(in: board, name: "To Do")
    }

    @Test func createCard() {
        let card = cardRepo.createCard(in: column, title: "Test Card")

        #expect(card.id != nil)
        #expect(card.title == "Test Card")
        #expect(card.column == column)
        #expect(card.isCompleted == false)
    }

    @Test func fetchCardsInColumn() {
        _ = cardRepo.createCard(in: column, title: "Card A")
        _ = cardRepo.createCard(in: column, title: "Card B")

        let cards = cardRepo.fetchCards(in: column)
        #expect(cards.count == 2)
        #expect(cards[0].title == "Card A")
        #expect(cards[1].title == "Card B")
    }

    @Test func updateCard() {
        let card = cardRepo.createCard(in: column, title: "Original")
        let label = Label(context: persistence.viewContext)
        label.id = UUID()
        label.name = "Urgent"
        label.colorHex = "#FF0000"
        label.createdAt = Date()
        try? persistence.viewContext.save()

        cardRepo.updateCard(card, title: "Updated", description: "A description", dueDate: Date(), isCompleted: true, label: label)

        #expect(card.title == "Updated")
        #expect(card.cardDescription == "A description")
        #expect(card.dueDate != nil)
        #expect(card.isCompleted == true)
        #expect(card.label == label)
    }

    @Test func deleteCard() {
        let card = cardRepo.createCard(in: column, title: "ToDelete")
        #expect(column.sortedCards.count == 1)

        cardRepo.deleteCard(card)
        #expect(column.sortedCards.count == 0)
    }

    @Test func moveCardBetweenColumns() {
        let column2 = boardRepo.createColumn(in: board, name: "Done")
        let card = cardRepo.createCard(in: column, title: "Moving Card")

        cardRepo.moveCard(card, to: column2, at: 0)

        #expect(card.column == column2)
        #expect(column.sortedCards.count == 0)
        #expect(column2.sortedCards.count == 1)
    }

    @Test func reorderCard() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let c = cardRepo.createCard(in: column, title: "C")

        cardRepo.reorderCard(c, to: 0, in: [a, b, c])

        let cards = column.sortedCards
        #expect(cards[0].title == "C")
    }

    @Test func fetchCardsWithDueDate() {
        let card1 = cardRepo.createCard(in: column, title: "Due Card")
        cardRepo.updateCard(card1, dueDate: Date().addingTimeInterval(86400))

        let card2 = cardRepo.createCard(in: column, title: "No Due Date")
        _ = card2

        let dueCards = cardRepo.fetchCardsWithDueDate()
        #expect(dueCards.count == 1)
        #expect(dueCards[0].title == "Due Card")
    }

    @Test func cardSortOrder() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")

        #expect(a.sortOrder < b.sortOrder)
    }

    @Test func deleteColumnCascadesCards() {
        _ = cardRepo.createCard(in: column, title: "Card")

        let cardFetch = Card.fetchRequest()
        #expect((try? persistence.viewContext.fetch(cardFetch))?.count == 1)

        boardRepo.deleteColumn(column)
        #expect((try? persistence.viewContext.fetch(cardFetch))?.count == 0)
    }

    // MARK: - Parent Board modifiedAt Propagation
    // Regression: adding/deleting/moving a card used to only bump
    // column.modifiedAt. BoardRowView's @ObservedObject only fires
    // on the Board's own attribute changes, so stale card counts
    // remained on the home page until app restart.

    @Test func createCardBumpsBoardModifiedAt() {
        let originalModified = board.modifiedAt ?? Date.distantPast
        Thread.sleep(forTimeInterval: 0.01)
        _ = cardRepo.createCard(in: column, title: "Card")
        #expect((board.modifiedAt ?? Date.distantPast) > originalModified)
    }

    @Test func deleteCardBumpsBoardModifiedAt() {
        let card = cardRepo.createCard(in: column, title: "Card")
        let beforeDelete = board.modifiedAt ?? Date.distantPast
        Thread.sleep(forTimeInterval: 0.01)
        cardRepo.deleteCard(card)
        #expect((board.modifiedAt ?? Date.distantPast) > beforeDelete)
    }

    @Test func moveCardBumpsBoardModifiedAt() {
        let column2 = boardRepo.createColumn(in: board, name: "Done")
        let card = cardRepo.createCard(in: column, title: "Card")
        let beforeMove = board.modifiedAt ?? Date.distantPast
        Thread.sleep(forTimeInterval: 0.01)
        cardRepo.moveCard(card, to: column2, at: 0)
        #expect((board.modifiedAt ?? Date.distantPast) > beforeMove)
    }

    // MARK: - Move Up / Down

    @Test func moveCardUp() {
        _ = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        _ = cardRepo.createCard(in: column, title: "C")

        cardRepo.moveCardUp(b)

        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["B", "A", "C"])
    }

    @Test func moveCardDown() {
        _ = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        _ = cardRepo.createCard(in: column, title: "C")

        cardRepo.moveCardDown(b)

        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["A", "C", "B"])
    }

    @Test func moveCardUpAtTopIsNoOp() {
        let a = cardRepo.createCard(in: column, title: "A")
        _ = cardRepo.createCard(in: column, title: "B")

        cardRepo.moveCardUp(a)

        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["A", "B"])
    }

    @Test func moveCardDownAtBottomIsNoOp() {
        _ = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")

        cardRepo.moveCardDown(b)

        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["A", "B"])
    }
}
