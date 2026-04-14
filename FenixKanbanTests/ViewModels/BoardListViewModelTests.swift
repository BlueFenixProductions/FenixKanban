import XCTest
import CoreData
@testable import FenixKanban

final class BoardListViewModelTests: XCTestCase {
    var persistence: PersistenceController!
    var viewModel: BoardListViewModel!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        viewModel = BoardListViewModel(context: persistence.viewContext)
    }

    override func tearDown() {
        viewModel = nil
        persistence = nil
        super.tearDown()
    }

    func testInitiallyEmpty() {
        XCTAssertTrue(viewModel.boards.isEmpty)
    }

    func testCreateBoard() {
        viewModel.createBoard(name: "Test", colorHex: "#FF0000")
        XCTAssertEqual(viewModel.boards.count, 1)
        XCTAssertEqual(viewModel.boards[0].name, "Test")
    }

    func testDeleteBoard() {
        viewModel.createBoard(name: "ToDelete", colorHex: nil)
        XCTAssertEqual(viewModel.boards.count, 1)

        viewModel.deleteBoard(viewModel.boards[0])
        XCTAssertEqual(viewModel.boards.count, 0)
    }

    func testDeleteBoardsAtOffsets() {
        viewModel.createBoard(name: "A", colorHex: nil)
        viewModel.createBoard(name: "B", colorHex: nil)
        viewModel.createBoard(name: "C", colorHex: nil)

        viewModel.deleteBoards(at: IndexSet(integer: 1))
        XCTAssertEqual(viewModel.boards.count, 2)
        XCTAssertEqual(viewModel.boards[0].name, "A")
        XCTAssertEqual(viewModel.boards[1].name, "C")
    }
}
