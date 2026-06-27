import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Unpaired board — local-only lifecycle transitions

@Suite("CardLifecycle — unpaired board (local-only)", .serialized)
@MainActor
struct CardLifecycleUnpairedTests {
    let mock = MockHTTPState()
    let persistence: PersistenceController
    let card: Card
    let viewModel: CardDetailViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Local Card")
        // No fizzyNumber — unpaired board
        try! persistence.viewContext.save()

        // No fizzyClient injected — unpaired
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext)
    }

    @Test("closeCard() sets .closed locally, zero network requests")
    func closeCardLocalOnly() async {
        #expect(card.lifecycleStatus == .active)
        await viewModel.closeCard()
        #expect(card.lifecycleStatus == .closed)
        #expect(mock.requests.isEmpty, "unpaired board must not make any network calls")
    }

    @Test("reopenCard() sets .active locally, zero network requests")
    func reopenCardLocalOnly() async {
        card.lifecycleStatus = .closed
        try! persistence.viewContext.save()
        await viewModel.reopenCard()
        #expect(card.lifecycleStatus == .active)
        #expect(mock.requests.isEmpty)
    }

    @Test("postponeCard() sets .notNow locally, zero network requests")
    func postponeCardLocalOnly() async {
        #expect(card.lifecycleStatus == .active)
        await viewModel.postponeCard()
        #expect(card.lifecycleStatus == .notNow)
        #expect(mock.requests.isEmpty)
    }
}

// MARK: - Paired board — optimistic + write-through

@Suite("CardLifecycle — paired board (write-through)", .serialized)
@MainActor
struct CardLifecyclePairedTests {
    let mock = MockHTTPState()
    let persistence: PersistenceController
    let card: Card
    let viewModel: CardDetailViewModel
    let pairingStore = FizzyCardPairingStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
    )

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Paired Card")
        try! persistence.viewContext.save()
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz42", fizzyNumber: 42, fizzyUpdatedAt: .now),
            for: card.id!
        )

        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: mock.makeSession(),
            clock: ImmediateClock()
        )
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client, pairingStore: pairingStore)
    }

    // MARK: closeCard

    @Test("closeCard() sets .closed optimistically and POSTs /cards/42/closure")
    func closeCardPostsClosure() async {
        mock.handler = { request in (Data(), .response(for: request, status: 204)) }
        await viewModel.closeCard()
        #expect(card.lifecycleStatus == .closed)
        let post = mock.requests.first { $0.httpMethod == "POST" }
        let url = post?.url
        #expect(url?.path.hasSuffix("/cards/42/closure") == true)
    }

    @Test("closeCard() failure reverts to .active and surfaces errorMessage")
    func closeCardFailureReverts() async {
        mock.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.closeCard()
        #expect(card.lifecycleStatus == .active)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: reopenCard

    @Test("reopenCard() on a closed card sets .active and DELETEs /cards/42/closure")
    func reopenCardDeletesClosure() async {
        mock.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.lifecycleStatus = .closed
        try! persistence.viewContext.save()
        await viewModel.reopenCard()
        #expect(card.lifecycleStatus == .active)
        let del = mock.requests.first { $0.httpMethod == "DELETE" }
        #expect(del?.url?.path.hasSuffix("/cards/42/closure") == true)
    }

    @Test("reopenCard() failure reverts to .closed and surfaces errorMessage")
    func reopenCardFailureReverts() async {
        mock.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        card.lifecycleStatus = .closed
        try! persistence.viewContext.save()
        await viewModel.reopenCard()
        #expect(card.lifecycleStatus == .closed)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: postponeCard

    @Test("postponeCard() sets .notNow optimistically and POSTs /cards/42/not_now")
    func postponeCardPostsNotNow() async {
        mock.handler = { request in (Data(), .response(for: request, status: 204)) }
        await viewModel.postponeCard()
        #expect(card.lifecycleStatus == .notNow)
        let post = mock.requests.first { $0.httpMethod == "POST" }
        #expect(post?.url?.path.hasSuffix("/cards/42/not_now") == true)
    }

    @Test("postponeCard() failure reverts to .active and surfaces errorMessage")
    func postponeCardFailureReverts() async {
        mock.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.postponeCard()
        #expect(card.lifecycleStatus == .active)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: deleted-card guard (#20 guard family)

    @Test("closeCard() revert stands down on a deleted card")
    func closeCardRevertGuardedOnDeletedCard() async {
        let context = persistence.viewContext
        let doomed = card
        mock.handler = { request in
            DispatchQueue.main.sync {
                if !doomed.isDeleted, doomed.managedObjectContext != nil {
                    context.delete(doomed)
                    try? context.save()
                }
            }
            return (Data("{\"error\":\"gone\"}".utf8), .response(for: request, status: 404))
        }
        await viewModel.closeCard()
        // No crash, no errorMessage (deleted card guard family)
        #expect(viewModel.errorMessage == nil)
    }
}

// MARK: - Filter helper tests (BoardViewModel-level)

@Suite("CardLifecycle — board-level filter (visibleCards)", .serialized)
@MainActor
struct CardLifecycleFilterTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column
    let activeCard: Card
    let closedCard: Card
    let notNowCard: Card
    let viewModel: BoardViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Filter Board")
        column = boardRepo.createColumn(in: board, name: "Col")
        activeCard = cardRepo.createCard(in: column, title: "Active")
        closedCard = cardRepo.createCard(in: column, title: "Closed")
        notNowCard = cardRepo.createCard(in: column, title: "NotNow")
        closedCard.lifecycleStatus = .closed
        notNowCard.lifecycleStatus = .notNow
        try! persistence.viewContext.save()
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    @Test("visibleCards(in:showClosed:false) excludes .closed and .notNow cards")
    func visibleCardsExcludesInactiveByDefault() {
        let visible = viewModel.visibleCards(in: column, showClosed: false)
        #expect(visible.map(\.title) == ["Active"])
    }

    @Test("visibleCards(in:showClosed:true) includes all cards")
    func visibleCardsIncludesAllWhenToggled() {
        let visible = viewModel.visibleCards(in: column, showClosed: true)
        #expect(visible.count == 3)
    }

    @Test("showClosedCards defaults to false")
    func showClosedCardsDefaultsFalse() {
        #expect(viewModel.showClosedCards == false)
    }
}
