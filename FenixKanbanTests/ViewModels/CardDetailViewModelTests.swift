import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("CardDetail ViewModel", .serialized)
@MainActor
struct CardDetailViewModelTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let card: Card
    let viewModel: CardDetailViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Test Card")
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext)
    }

    @Test func initialValues() {
        #expect(viewModel.title == "Test Card")
        #expect(viewModel.cardDescription == "")
        #expect(viewModel.dueDate == nil)
        #expect(viewModel.isCompleted == false)
        #expect(viewModel.selectedLabels.isEmpty)
    }

    @Test func saveUpdatesCard() {
        viewModel.title = "Updated Title"
        viewModel.cardDescription = "A description"
        viewModel.isCompleted = true
        viewModel.save()

        #expect(card.title == "Updated Title")
        #expect(card.cardDescription == "A description")
        #expect(card.isCompleted == true)
    }

    @Test func clearDueDate() {
        viewModel.dueDate = Date()
        viewModel.save()
        #expect(card.dueDate != nil)

        viewModel.clearDueDate()
        #expect(card.dueDate == nil)
        #expect(viewModel.dueDate == nil)
    }

    @Test func toggleLabelAddsAndRemoves() async {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        await viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels == [label])
        #expect((card.labels as? Set<Label>) == [label])

        await viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
    }

    @Test func multipleLabelsCoexist() async {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let bug = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        let urgent = labelRepo.createLabel(name: "Urgent", colorHex: "#00FF00")

        await viewModel.toggleLabel(bug)
        await viewModel.toggleLabel(urgent)
        #expect(viewModel.selectedLabels == [bug, urgent])
        #expect(viewModel.sortedSelectedLabels.map(\.name) == ["Bug", "Urgent"])
    }

    @Test func clearLabels() async {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        await viewModel.toggleLabel(label)

        viewModel.clearLabels()
        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
    }

    @Test func unpairedCardHasNoStepsVM() {
        #expect(viewModel.stepsViewModel == nil)
    }

    @Test("paired card without a client gets no steps view model")
    func pairedCardWithoutClientHasNoStepsVM() {
        // fizzyNumber > 0 alone isn't enough — both pairing AND a live
        // client are required (conjunction in CardDetailViewModel.init).
        card.fizzyNumber = 7
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext)
        #expect(vm.stepsViewModel == nil)
    }

    @Test("unpaired card cannot edit assignments")
    func unpairedCardCannotEditAssignments() async throws {
        #expect(viewModel.canEditAssignments == false)
    }

    @Test("unpaired card: toggleAssignment is a no-op with zero network")
    func unpairedToggleAssignmentNoOp() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)
        await viewModel.toggleAssignment(user)
        #expect(viewModel.assignees.isEmpty)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("unpaired card: watch/pin toggles are no-ops with zero network")
    func unpairedWatchPinNoOp() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        await viewModel.toggleWatched()
        await viewModel.togglePinned()
        #expect(viewModel.isWatched == false)
        #expect(viewModel.isPinned == false)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("unpaired card is not fizzy-paired")
    func unpairedCardIsNotFizzyPaired() async throws {
        #expect(viewModel.isFizzyPaired == false)
    }

    @Test("toggleGolden flips isGolden and updates modifiedAt")
    func toggleGoldenFlips() async throws {
        #expect(card.isGolden == false)
        let before = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)

        await viewModel.toggleGolden()
        #expect(card.isGolden == true)
        #expect((card.modifiedAt ?? .distantPast) > (before ?? .distantPast))

        await viewModel.toggleGolden()
        #expect(card.isGolden == false)
    }
}

@Suite("CardDetail ViewModel — fizzy tag push", .serialized)
@MainActor
struct CardDetailViewModelTagPushTests {
    let persistence: PersistenceController
    let card: Card
    let label: Label
    let viewModel: CardDetailViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Paired Card")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        label = LabelRepository(context: persistence.viewContext).createLabel(name: "bug", colorHex: "#FF0000")
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
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
    }

    @Test("paired card with a client exposes a steps view model")
    func pairedCardExposesStepsVM() {
        #expect(viewModel.stepsViewModel != nil)
    }

    @Test("toggle on a paired card POSTs the tagging toggle")
    func toggleOnPairedCardPosts() async throws {
        MockURLProtocol.handler = { request in
            (Data(), .response(for: request, status: 204))
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels == [label])
        let post = MockURLProtocol.requests.first { $0.httpMethod == "POST" }
        let url = try #require(post?.url)
        #expect(url.path.hasSuffix("/cards/7/taggings"))
        MockURLProtocol.reset()
    }

    @Test("422 from taggings reverts the toggle and surfaces an error")
    func failedPushReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("failed push does not clobber a newer toggle of the same label")
    func failedPushRespectsNewerState() async throws {
        // First POST is held open by a gate, then fails (422); every later
        // POST succeeds (204). A second toggle of the same label runs to
        // completion while the first is in flight — the first's failure
        // must leave the newer state alone (no revert, no redundant save).
        let (gate, releaseFirstPush) = AsyncStream.makeStream(of: Void.self)
        let calls = TagPushCallCounter()
        MockURLProtocol.delayedHandler = { request in
            if calls.next() == 1 {
                var blocked = gate.makeAsyncIterator()
                _ = await blocked.next()
                return (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
            }
            return (Data(), .response(for: request, status: 204))
        }

        // First toggle: ON — optimistic insert, then suspends on the gated POST.
        async let firstToggle: Void = viewModel.toggleLabel(label)
        while calls.count == 0 { await Task.yield() }

        // Second toggle: OFF — completes (204) while the first is in flight.
        await viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels.isEmpty)
        let stampAfterSecondToggle = card.modifiedAt

        // Fail the first push. Its catch must see the newer (OFF) state and
        // not clobber it back to pre-first-toggle state via a revert+save.
        releaseFirstPush.yield()
        await firstToggle

        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
        #expect(card.modifiedAt == stampAfterSecondToggle)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("unpaired card toggles locally without any network call")
    func unpairedCardStaysLocal() async throws {
        card.fizzyNumber = 0
        card.fizzyID = nil
        MockURLProtocol.handler = { _ in
            Issue.record("no network call expected for unpaired card")
            throw URLError(.unsupportedURL)
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels == [label])
        #expect(MockURLProtocol.requests.isEmpty)
        MockURLProtocol.reset()
    }
}

@Suite("CardDetailViewModel assignment push", .serialized)
@MainActor
struct CardDetailViewModelAssignmentPushTests {
    let persistence: PersistenceController
    let card: Card
    let client: FizzyClient
    let viewModel: CardDetailViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Paired Card")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        try! persistence.viewContext.save()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
    }

    @Test("paired card with client exposes assignment editing")
    func pairedCardCanEditAssignments() async throws {
        #expect(viewModel.canEditAssignments == true)
    }

    @Test("toggle POSTs /cards/7/assignments with assignee_id and updates the blob")
    func togglePostsAssignment() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(viewModel.assignees.map(\.id) == ["u9"])
        #expect(card.assignees.map(\.id) == ["u9"])
        let post = MockURLProtocol.requests.first { $0.httpMethod == "POST" }
        #expect(post?.url?.path.hasSuffix("/cards/7/assignments") == true)
        MockURLProtocol.reset()
    }

    @Test("toggle on an already-assigned user removes them")
    func toggleRemovesAssigned() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        // Seed the blob, then build a fresh view model so init picks it up.
        card.assignees = [CardAssignee(id: "u9", name: "Grace Hopper")]
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await vm.toggleAssignment(user)

        #expect(vm.assignees.isEmpty)
        #expect(card.assignees.isEmpty)
        MockURLProtocol.reset()
    }

    @Test("failed POST (422) reverts the optimistic change and surfaces an error")
    func failedToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(viewModel.assignees.isEmpty)
        #expect(card.assignees.isEmpty)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("failed POST does not clobber a newer toggle of the same user")
    func failedToggleRespectsNewerState() async throws {
        // First POST is held open by a gate, then fails (422); every later
        // POST succeeds (204). A second toggle of the same user runs to
        // completion while the first is in flight — the first's failure
        // must leave the newer state alone (no revert, no redundant save).
        let (gate, releaseFirstPush) = AsyncStream.makeStream(of: Void.self)
        let calls = TagPushCallCounter()
        MockURLProtocol.delayedHandler = { request in
            if calls.next() == 1 {
                var blocked = gate.makeAsyncIterator()
                _ = await blocked.next()
                return (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
            }
            return (Data(), .response(for: request, status: 204))
        }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        // First toggle: ON — optimistic append, then suspends on the gated POST.
        async let firstToggle: Void = viewModel.toggleAssignment(user)
        while calls.count == 0 { await Task.yield() }

        // Second toggle: OFF — completes (204) while the first is in flight.
        await viewModel.toggleAssignment(user)
        #expect(viewModel.assignees.isEmpty)
        let stampAfterSecondToggle = card.modifiedAt

        // Fail the first push. Its catch must see the newer (OFF) state and
        // not clobber it back to pre-first-toggle state via a revert+save.
        releaseFirstPush.yield()
        await firstToggle

        #expect(!viewModel.assignees.contains { $0.id == "u9" })
        #expect(card.assignees.isEmpty)
        #expect(card.modifiedAt == stampAfterSecondToggle)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }
}

@Suite("CardDetailViewModel watch/pin push", .serialized)
@MainActor
struct CardDetailViewModelWatchPinPushTests {
    let persistence: PersistenceController
    let card: Card
    let client: FizzyClient
    let viewModel: CardDetailViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Paired Card")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        try! persistence.viewContext.save()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
    }

    @Test("paired card with client is fizzy-paired")
    func pairedCardIsFizzyPaired() async throws {
        #expect(viewModel.isFizzyPaired == true)
    }

    @Test("toggleWatched POSTs /cards/7/watch and sets the flag")
    func watchPostsToWatchEndpoint() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        let stampBeforeToggle = card.modifiedAt
        await viewModel.toggleWatched()
        #expect(viewModel.isWatched == true)
        #expect(card.isWatched == true)
        // Watch flag must NOT bump modifiedAt: it's outside the card-content
        // LWW contract, and a bump makes the card look newer than
        // fizzyUpdatedAt — triggering a spurious echo-PUT on the next sync.
        #expect(card.modifiedAt == stampBeforeToggle)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/7/watch") == true)
        MockURLProtocol.reset()
    }

    @Test("toggleWatched on a watched card DELETEs /cards/7/watch")
    func unwatchDeletes() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.isWatched = true
        try persistence.viewContext.save()
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
        await vm.toggleWatched()
        #expect(vm.isWatched == false)
        #expect(card.isWatched == false)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.path.hasSuffix("/cards/7/watch") == true)
        MockURLProtocol.reset()
    }

    @Test("togglePinned POSTs /cards/7/pin and sets the flag")
    func pinPostsToPinEndpoint() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        let stampBeforeToggle = card.modifiedAt
        await viewModel.togglePinned()
        #expect(viewModel.isPinned == true)
        #expect(card.isPinned == true)
        // Pin flag must NOT bump modifiedAt (echo-PUT guard, same as watch).
        #expect(card.modifiedAt == stampBeforeToggle)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/7/pin") == true)
        MockURLProtocol.reset()
    }

    @Test("togglePinned on a pinned card DELETEs /cards/7/pin")
    func unpinDeletes() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.isPinned = true
        try persistence.viewContext.save()
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
        await vm.togglePinned()
        #expect(vm.isPinned == false)
        #expect(card.isPinned == false)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.path.hasSuffix("/cards/7/pin") == true)
        MockURLProtocol.reset()
    }

    @Test("failed watch toggle (422) reverts and surfaces an error")
    func failedWatchToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.toggleWatched()
        #expect(viewModel.isWatched == false)
        #expect(card.isWatched == false)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("failed pin toggle (422) reverts and surfaces an error")
    func failedPinToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.togglePinned()
        #expect(viewModel.isPinned == false)
        #expect(card.isPinned == false)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("toggleGolden on a paired card POSTs /cards/7/goldness")
    func goldenTogglePostsGoldness() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        let stampBeforeToggle = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)
        await viewModel.toggleGolden()
        #expect(card.isGolden == true)
        // Unlike watch/pin, golden DOES bump modifiedAt: golden is pulled
        // card content, and the bump blocks the LWW pull branch until the
        // push cycle completes (stale-pull revert protection, #19 wave 3).
        #expect((card.modifiedAt ?? .distantPast) > (stampBeforeToggle ?? .distantPast))
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/7/goldness") == true)
        MockURLProtocol.reset()
    }

    @Test("toggleGolden on a golden paired card DELETEs /cards/7/goldness")
    func goldenToggleUnmarksDeletes() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.isGolden = true
        try persistence.viewContext.save()
        await viewModel.toggleGolden()
        #expect(card.isGolden == false)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.path.hasSuffix("/cards/7/goldness") == true)
        MockURLProtocol.reset()
    }

    @Test("failed golden push (422) reverts and surfaces an error")
    func failedGoldenToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.toggleGolden()
        #expect(card.isGolden == false)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }
}

/// Thread-safe call counter for `MockURLProtocol.delayedHandler`, which is
/// invoked off the main actor (URL loading threads).
private final class TagPushCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
