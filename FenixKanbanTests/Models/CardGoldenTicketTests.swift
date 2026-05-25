import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card isGolden attribute", .serialized)
@MainActor
struct CardGoldenTicketTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = cardRepo.createCard(in: column, title: "T")
    }

    @Test("isGolden defaults to false on insert")
    func defaultIsFalse() {
        #expect(card.isGolden == false)
    }

    @Test("isGolden round-trips through save/fetch")
    func persistsAcrossSave() throws {
        card.isGolden = true
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.isGolden == true)
    }
}
