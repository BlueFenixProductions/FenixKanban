import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BoardViewModel golden toggle", .serialized)
@MainActor
struct BoardViewModelGoldenTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column
    let viewModel: BoardViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    @Test("toggleGolden(for:) flips state and bumps modifiedAt")
    func toggleByCardFlips() async throws {
        let card = cardRepo.createCard(in: column, title: "T")
        let before = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)  // ensure modifiedAt advances

        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == true)
        #expect((card.modifiedAt ?? .distantPast) > (before ?? .distantPast))

        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == false)
    }

    @Test("toggleGolden(cardID:) finds and flips the right card")
    func toggleByIDFlips() {
        let card = cardRepo.createCard(in: column, title: "T")
        let uuid = card.id!
        viewModel.toggleGolden(cardID: uuid)
        #expect(card.isGolden == true)
    }

    @Test("toggleGolden(cardID:) is a no-op for unknown UUID")
    func toggleByIDIgnoresUnknown() {
        let card = cardRepo.createCard(in: column, title: "T")
        viewModel.toggleGolden(cardID: UUID())
        #expect(card.isGolden == false)
    }

    @Test("Toggling a non-golden card lifts it above non-golden siblings")
    func toggleReorders() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let c = cardRepo.createCard(in: column, title: "C")
        // a < b < c by sortOrder

        viewModel.toggleGolden(for: c)
        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["C", "A", "B"])
        _ = (a, b)  // silence unused warnings
    }
}
