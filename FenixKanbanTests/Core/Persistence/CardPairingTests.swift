import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card pairing resolution", .serialized)
@MainActor
struct CardPairingTests {
    let persistence: PersistenceController
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = CardRepository(context: persistence.viewContext).createCard(in: column, title: "Card")
    }

    private func makeStore() -> FizzyCardPairingStore {
        FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
    }

    @Test("falls back to the CoreData attribute when the store has no entry")
    func fallbackToAttribute() {
        let store = makeStore()
        card.fizzyNumber = 42
        card.fizzyID = "fz-42"
        #expect(card.resolvedFizzyNumber(store) == 42)
        #expect(card.resolvedFizzyID(store) == "fz-42")
    }

    @Test("store value wins over the CoreData attribute")
    func storeWins() {
        let store = makeStore()
        card.fizzyNumber = 42
        card.fizzyID = "fz-42"
        store.setPairing(
            FizzyCardPairing(fizzyID: "fz-99", fizzyNumber: 99, fizzyUpdatedAt: .now),
            for: card.id!
        )
        #expect(card.resolvedFizzyNumber(store) == 99)
        #expect(card.resolvedFizzyID(store) == "fz-99")
    }

    @Test("unpaired in both store and attribute yields 0 / nil")
    func unpairedDefaults() {
        let store = makeStore()
        #expect(card.resolvedFizzyNumber(store) == 0)
        #expect(card.resolvedFizzyID(store) == nil)
    }
}
