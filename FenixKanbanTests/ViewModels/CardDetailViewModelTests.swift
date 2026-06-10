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

    @Test("toggleGolden flips isGolden and updates modifiedAt")
    func toggleGoldenFlips() async throws {
        #expect(card.isGolden == false)
        let before = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)

        viewModel.toggleGolden()
        #expect(card.isGolden == true)
        #expect((card.modifiedAt ?? .distantPast) > (before ?? .distantPast))

        viewModel.toggleGolden()
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
