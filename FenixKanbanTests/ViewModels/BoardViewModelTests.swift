import Testing
import CoreData
@testable import FenixKanban

@Suite("Board ViewModel", .serialized)
@MainActor
struct BoardViewModelTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let board: Board
    let viewModel: BoardViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    @Test func addColumn() {
        viewModel.addColumn(name: "To Do")
        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns[0].name == "To Do")
    }

    @Test func deleteColumn() {
        viewModel.addColumn(name: "To Do")
        viewModel.deleteColumn(viewModel.columns[0])
        #expect(viewModel.columns.count == 0)
    }

    @Test func renameColumn() {
        viewModel.addColumn(name: "Original")
        viewModel.updateColumn(viewModel.columns[0], name: "Renamed")
        #expect(viewModel.columns[0].name == "Renamed")
    }

    @Test func addColumnWithColor() {
        viewModel.addColumn(name: "Dev", colorHex: "#0F3460")
        #expect(viewModel.columns[0].colorHex == "#0F3460")
    }

    @Test func updateColumnColor() {
        viewModel.addColumn(name: "Col")
        viewModel.updateColumn(viewModel.columns[0], colorHex: "#E94560")
        #expect(viewModel.columns[0].colorHex == "#E94560")
    }

    @Test func addCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Test Card")
        #expect(column.sortedCards.count == 1)
        #expect(column.sortedCards[0].title == "Test Card")
    }

    @Test func deleteCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Card")
        let card = column.sortedCards[0]
        viewModel.deleteCard(card)
        #expect(column.sortedCards.count == 0)
    }
}
