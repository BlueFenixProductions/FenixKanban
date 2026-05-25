import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card sort: golden floats to top", .serialized)
@MainActor
struct CardRepositoryGoldenSortTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let column: Column

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
    }

    private func makeCard(title: String, sortOrder: Int32, isGolden: Bool) -> Card {
        let card = cardRepo.createCard(in: column, title: title)
        card.sortOrder = sortOrder
        card.isGolden = isGolden
        try? persistence.viewContext.save()
        return card
    }

    @Test("Golden card with higher sortOrder still sorts above non-golden")
    func goldenFloatsAbove() {
        _ = makeCard(title: "A", sortOrder: 0, isGolden: false)
        _ = makeCard(title: "B", sortOrder: 1000, isGolden: true)
        _ = makeCard(title: "C", sortOrder: 2000, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["B", "A", "C"])
    }

    @Test("Manual reorder within golden group is preserved")
    func goldenInternalOrder() {
        _ = makeCard(title: "G1", sortOrder: 10, isGolden: true)
        _ = makeCard(title: "G2", sortOrder: 5, isGolden: true)
        _ = makeCard(title: "N1", sortOrder: 100, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["G2", "G1", "N1"])
    }

    @Test("All-non-golden behavior unchanged")
    func noGoldenSortsByOrder() {
        _ = makeCard(title: "X", sortOrder: 2, isGolden: false)
        _ = makeCard(title: "Y", sortOrder: 1, isGolden: false)
        _ = makeCard(title: "Z", sortOrder: 3, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["Y", "X", "Z"])
    }
}
