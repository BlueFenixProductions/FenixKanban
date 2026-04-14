import XCTest
import CoreData
@testable import FenixKanban

final class BoardRepositoryTests: XCTestCase {
    var persistence: PersistenceController!
    var repository: BoardRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = BoardRepository(context: persistence.viewContext)
    }

    override func tearDown() {
        repository = nil
        persistence = nil
        super.tearDown()
    }

    func testCreateBoard() {
        let board = repository.createBoard(name: "Test Board", colorHex: "#FF0000")

        XCTAssertNotNil(board.id)
        XCTAssertEqual(board.name, "Test Board")
        XCTAssertEqual(board.colorHex, "#FF0000")
        XCTAssertNotNil(board.createdAt)
        XCTAssertNotNil(board.modifiedAt)
    }

    func testFetchAllBoards() {
        _ = repository.createBoard(name: "Board A")
        _ = repository.createBoard(name: "Board B")

        let boards = repository.fetchAllBoards()
        XCTAssertEqual(boards.count, 2)
        XCTAssertEqual(boards[0].name, "Board A")
        XCTAssertEqual(boards[1].name, "Board B")
    }

    func testBoardSortOrder() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        XCTAssertTrue(a.sortOrder < b.sortOrder)
        XCTAssertTrue(b.sortOrder < c.sortOrder)
    }

    func testUpdateBoard() {
        let board = repository.createBoard(name: "Original")
        let originalModified = board.modifiedAt

        Thread.sleep(forTimeInterval: 0.01)
        repository.updateBoard(board, name: "Updated", colorHex: "#00FF00")

        XCTAssertEqual(board.name, "Updated")
        XCTAssertEqual(board.colorHex, "#00FF00")
        XCTAssertTrue(board.modifiedAt! > originalModified!)
    }

    func testDeleteBoard() {
        let board = repository.createBoard(name: "ToDelete")
        XCTAssertEqual(repository.fetchAllBoards().count, 1)

        repository.deleteBoard(board)
        XCTAssertEqual(repository.fetchAllBoards().count, 0)
    }

    func testDeleteBoardCascadesColumns() {
        let board = repository.createBoard(name: "Board")
        _ = repository.createColumn(in: board, name: "Column")

        let columnFetch = Column.fetchRequest()
        XCTAssertEqual((try? persistence.viewContext.fetch(columnFetch))?.count, 1)

        repository.deleteBoard(board)
        XCTAssertEqual((try? persistence.viewContext.fetch(columnFetch))?.count, 0)
    }

    func testCreateColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "To Do")

        XCTAssertNotNil(column.id)
        XCTAssertEqual(column.name, "To Do")
        XCTAssertEqual(column.board, board)
        XCTAssertEqual(board.sortedColumns.count, 1)
    }

    func testColumnSortOrder() {
        let board = repository.createBoard(name: "Board")
        let col1 = repository.createColumn(in: board, name: "First")
        let col2 = repository.createColumn(in: board, name: "Second")

        XCTAssertTrue(col1.sortOrder < col2.sortOrder)
    }

    func testUpdateColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Original")

        repository.updateColumn(column, name: "Renamed")
        XCTAssertEqual(column.name, "Renamed")
    }

    func testDeleteColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Col")

        repository.deleteColumn(column)
        XCTAssertEqual(board.sortedColumns.count, 0)
    }

    func testReorderBoard() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        repository.reorderBoard(c, to: 0, in: [a, b, c])

        let boards = repository.fetchAllBoards()
        XCTAssertEqual(boards[0].name, "C")
    }
}
