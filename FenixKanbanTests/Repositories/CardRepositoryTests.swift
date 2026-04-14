import XCTest
import CoreData
@testable import FenixKanban

final class CardRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var cardRepo: CardRepository!
    var board: Board!
    var column: Column!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        column = boardRepo.createColumn(in: board, name: "To Do")
    }

    override func tearDown() {
        board = nil
        column = nil
        cardRepo = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateCard() {
        let card = cardRepo.createCard(in: column, title: "Test Card")

        XCTAssertNotNil(card.id)
        XCTAssertEqual(card.title, "Test Card")
        XCTAssertEqual(card.column, column)
        XCTAssertFalse(card.isCompleted)
    }

    func testFetchCardsInColumn() {
        _ = cardRepo.createCard(in: column, title: "Card A")
        _ = cardRepo.createCard(in: column, title: "Card B")

        let cards = cardRepo.fetchCards(in: column)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].title, "Card A")
        XCTAssertEqual(cards[1].title, "Card B")
    }

    func testUpdateCard() {
        let card = cardRepo.createCard(in: column, title: "Original")
        let label = Label(context: persistence.viewContext)
        label.id = UUID()
        label.name = "Urgent"
        label.colorHex = "#FF0000"
        label.createdAt = Date()
        try? persistence.viewContext.save()

        cardRepo.updateCard(card, title: "Updated", description: "A description", dueDate: Date(), isCompleted: true, label: label)

        XCTAssertEqual(card.title, "Updated")
        XCTAssertEqual(card.cardDescription, "A description")
        XCTAssertNotNil(card.dueDate)
        XCTAssertTrue(card.isCompleted)
        XCTAssertEqual(card.label, label)
    }

    func testDeleteCard() {
        let card = cardRepo.createCard(in: column, title: "ToDelete")
        XCTAssertEqual(column.sortedCards.count, 1)

        cardRepo.deleteCard(card)
        XCTAssertEqual(column.sortedCards.count, 0)
    }

    func testMoveCardBetweenColumns() {
        let column2 = boardRepo.createColumn(in: board, name: "Done")
        let card = cardRepo.createCard(in: column, title: "Moving Card")

        cardRepo.moveCard(card, to: column2, at: 0)

        XCTAssertEqual(card.column, column2)
        XCTAssertEqual(column.sortedCards.count, 0)
        XCTAssertEqual(column2.sortedCards.count, 1)
    }

    func testReorderCard() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let c = cardRepo.createCard(in: column, title: "C")

        cardRepo.reorderCard(c, to: 0, in: [a, b, c])

        let cards = column.sortedCards
        XCTAssertEqual(cards[0].title, "C")
    }

    func testFetchCardsWithDueDate() {
        let card1 = cardRepo.createCard(in: column, title: "Due Card")
        cardRepo.updateCard(card1, dueDate: Date().addingTimeInterval(86400))

        let card2 = cardRepo.createCard(in: column, title: "No Due Date")
        _ = card2 // no due date set

        let dueCards = cardRepo.fetchCardsWithDueDate()
        XCTAssertEqual(dueCards.count, 1)
        XCTAssertEqual(dueCards[0].title, "Due Card")
    }

    func testCardSortOrder() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")

        XCTAssertTrue(a.sortOrder < b.sortOrder)
    }

    func testDeleteColumnCascadesCards() {
        _ = cardRepo.createCard(in: column, title: "Card")

        let cardFetch = Card.fetchRequest()
        XCTAssertEqual((try? persistence.viewContext.fetch(cardFetch))?.count, 1)

        boardRepo.deleteColumn(column)
        XCTAssertEqual((try? persistence.viewContext.fetch(cardFetch))?.count, 0)
    }
}
