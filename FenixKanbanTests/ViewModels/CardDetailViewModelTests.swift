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

    @Test func toggleLabelAddsAndRemoves() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels == [label])
        #expect((card.labels as? Set<Label>) == [label])

        viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
    }

    @Test func multipleLabelsCoexist() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let bug = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        let urgent = labelRepo.createLabel(name: "Urgent", colorHex: "#00FF00")

        viewModel.toggleLabel(bug)
        viewModel.toggleLabel(urgent)
        #expect(viewModel.selectedLabels == [bug, urgent])
        #expect(viewModel.sortedSelectedLabels.map(\.name) == ["Bug", "Urgent"])
    }

    @Test func clearLabels() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        viewModel.toggleLabel(label)

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
