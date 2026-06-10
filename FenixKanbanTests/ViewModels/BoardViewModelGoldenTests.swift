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

@Suite("BoardViewModel golden push", .serialized)
@MainActor
struct BoardViewModelGoldenPushTests {
    let persistence: PersistenceController
    let card: Card
    let unpairedCard: Card
    let viewModel: BoardViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = cardRepo.createCard(in: column, title: "Paired")
        card.fizzyID = "fzG"
        card.fizzyNumber = 9
        unpairedCard = cardRepo.createCard(in: column, title: "Unpaired")
        try! persistence.viewContext.save()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
        viewModel = BoardViewModel(board: board, context: persistence.viewContext, fizzyClient: client)
    }

    @Test("board golden toggle on a paired card pushes goldness")
    func boardTogglePushesGoldness() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == true)
        // The board push is fire-and-forget — await it with a bounded yield loop.
        var spins = 0
        while MockURLProtocol.requests.isEmpty && spins < 1000 { await Task.yield(); spins += 1 }
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/9/goldness") == true)
        #expect(card.isGolden == true)  // successful push must not revert
        MockURLProtocol.reset()
    }

    @Test("board golden push failure silently reverts the card")
    func boardTogglePushFailureReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == true)
        // Fire-and-forget push fails — wait for the silent revert to land.
        var spins = 0
        while card.isGolden && spins < 1000 { await Task.yield(); spins += 1 }
        #expect(card.isGolden == false)
        MockURLProtocol.reset()
    }

    @Test("board golden toggle on an unpaired card stays local, zero network")
    func boardToggleUnpairedNoNetwork() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        viewModel.toggleGolden(for: unpairedCard)
        #expect(unpairedCard.isGolden == true)
        for _ in 0..<50 { await Task.yield() }
        #expect(MockURLProtocol.requests.isEmpty)
    }
}
