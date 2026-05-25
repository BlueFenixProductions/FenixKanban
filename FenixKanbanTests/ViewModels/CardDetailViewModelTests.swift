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
        #expect(viewModel.selectedLabel == nil)
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

    @Test func selectLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        viewModel.selectLabel(label)
        #expect(viewModel.selectedLabel == label)
        #expect(card.label == label)
    }

    @Test func clearLabel() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        viewModel.selectLabel(label)

        viewModel.clearLabel()
        #expect(viewModel.selectedLabel == nil)
        #expect(card.label == nil)
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
