import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card Entity", .serialized)
@MainActor
struct CardEntityTests {

    private func makeContext() -> (PersistenceController, BoardRepository, CardRepository, Column) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        return (persistence, boardRepo, cardRepo, column)
    }

    @Test func initFromCardPopulatesFields() throws {
        let (_, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Fix bug")
        cardRepo.updateCard(card, description: "Detail", dueDate: Date(timeIntervalSince1970: 100), isCompleted: false)

        let entity = try CardEntity(from: card)

        #expect(entity.id == card.id)
        #expect(entity.title == "Fix bug")
        #expect(entity.cardDescription == "Detail")
        #expect(entity.dueDate == Date(timeIntervalSince1970: 100))
        #expect(entity.isCompleted == false)
    }

    @Test func initFromCardThrowsWhenIdMissing() {
        let (persistence, _, _, _) = makeContext()
        let card = Card(context: persistence.viewContext)
        card.title = "No-ID Card"

        #expect(throws: (any Error).self) {
            try CardEntity(from: card)
        }
    }

    @Test func displayRepresentationUsesTitle() throws {
        let (_, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Fix bug")

        let entity = try CardEntity(from: card)

        #expect(String(describing: entity.displayRepresentation).contains("Fix bug"))
    }

    @Test func queryByIDReturnsMatchingCards() async throws {
        let (persistence, _, cardRepo, column) = makeContext()
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let uuidA = try #require(a.id)
        let uuidB = try #require(b.id)

        let query = CardQuery(context: persistence.viewContext)
        let results = try await query.entities(for: [uuidA, uuidB])

        let titles = Set(results.map(\.title))
        #expect(titles == ["A", "B"])
    }

    @Test func initFromCardPopulatesIsGolden() throws {
        let (persistence, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Pay rent")
        card.isGolden = true
        try persistence.viewContext.save()

        let entity = try CardEntity(from: card)

        #expect(entity.isGolden == true)
    }

    @Test func displayRepresentationShowsGoldenSubtitle() throws {
        let (persistence, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Pay rent")
        card.isGolden = true
        try persistence.viewContext.save()

        let entity = try CardEntity(from: card)

        #expect(String(describing: entity.displayRepresentation).contains("Golden ticket"))
    }

    @Test func suggestedEntitiesReturnsAllCardsSortedByTitle() async throws {
        let (persistence, _, cardRepo, column) = makeContext()
        _ = cardRepo.createCard(in: column, title: "Charlie")
        _ = cardRepo.createCard(in: column, title: "Alpha")
        _ = cardRepo.createCard(in: column, title: "Bravo")

        let query = CardQuery(context: persistence.viewContext)
        let results = try await query.suggestedEntities()

        #expect(results.map(\.title) == ["Alpha", "Bravo", "Charlie"])
    }
}
