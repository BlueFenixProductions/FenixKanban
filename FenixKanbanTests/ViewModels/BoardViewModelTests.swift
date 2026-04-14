import XCTest
import CoreData
@testable import FenixKanban

final class BoardViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var boardRepo: BoardRepository!
    var board: Board!
    var viewModel: BoardViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "Test Board")
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        board = nil
        boardRepo = nil
        persistence = nil
        super.tearDown()
    }

    func testAddColumn() {
        viewModel.addColumn(name: "To Do")
        XCTAssertEqual(viewModel.columns.count, 1)
        XCTAssertEqual(viewModel.columns[0].name, "To Do")
    }

    func testDeleteColumn() {
        viewModel.addColumn(name: "To Do")
        viewModel.deleteColumn(viewModel.columns[0])
        XCTAssertEqual(viewModel.columns.count, 0)
    }

    func testRenameColumn() {
        viewModel.addColumn(name: "Original")
        viewModel.renameColumn(viewModel.columns[0], to: "Renamed")
        XCTAssertEqual(viewModel.columns[0].name, "Renamed")
    }

    func testAddCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Test Card")
        XCTAssertEqual(column.sortedCards.count, 1)
        XCTAssertEqual(column.sortedCards[0].title, "Test Card")
    }

    func testDeleteCard() {
        viewModel.addColumn(name: "To Do")
        let column = viewModel.columns[0]
        viewModel.addCard(to: column, title: "Card")
        let card = column.sortedCards[0]
        viewModel.deleteCard(card)
        XCTAssertEqual(column.sortedCards.count, 0)
    }
}
