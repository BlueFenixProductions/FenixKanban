import Testing
import CoreData
import Foundation
@testable import FenixKanban

// .serialized because each test instantiates its own PersistenceController
// (in-memory NSPersistentContainer). Running them in parallel causes
// multiple NSManagedObjectModel instances to be live simultaneously, which
// trips Core Data's "Multiple NSEntityDescriptions claim..." warning and
// can crash entity lookups.
@Suite("Board Repository", .serialized)
@MainActor
struct BoardRepositoryTests {
    let persistence: PersistenceController
    let repository: BoardRepository

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        repository = BoardRepository(context: persistence.viewContext)
    }

    @Test func createBoard() {
        let board = repository.createBoard(name: "Test Board", colorHex: "#FF0000")

        #expect(board.id != nil)
        #expect(board.name == "Test Board")
        #expect(board.colorHex == "#FF0000")
        #expect(board.createdAt != nil)
        #expect(board.modifiedAt != nil)
    }

    @Test func fetchAllBoards() {
        _ = repository.createBoard(name: "Board A")
        _ = repository.createBoard(name: "Board B")

        let boards = repository.fetchAllBoards()
        #expect(boards.count == 2)
        #expect(boards[0].name == "Board A")
        #expect(boards[1].name == "Board B")
    }

    @Test func boardSortOrder() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        #expect(a.sortOrder < b.sortOrder)
        #expect(b.sortOrder < c.sortOrder)
    }

    @Test func updateBoard() {
        let board = repository.createBoard(name: "Original")
        let originalModified = board.modifiedAt

        Thread.sleep(forTimeInterval: 0.01)
        repository.updateBoard(board, name: "Updated", colorHex: "#00FF00")

        #expect(board.name == "Updated")
        #expect(board.colorHex == "#00FF00")
        #expect((board.modifiedAt ?? .distantPast) > (originalModified ?? .distantPast))
    }

    @Test func deleteBoard() {
        let board = repository.createBoard(name: "ToDelete")
        #expect(repository.fetchAllBoards().count == 1)

        repository.deleteBoard(board)
        #expect(repository.fetchAllBoards().count == 0)
    }

    @Test func deleteBoardCascadesColumns() {
        let board = repository.createBoard(name: "Board")
        _ = repository.createColumn(in: board, name: "Column")

        let columnFetch = Column.fetchRequest()
        #expect((try? persistence.viewContext.fetch(columnFetch))?.count == 1)

        repository.deleteBoard(board)
        #expect((try? persistence.viewContext.fetch(columnFetch))?.count == 0)
    }

    @Test func createColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "To Do")

        #expect(column.id != nil)
        #expect(column.name == "To Do")
        #expect(column.board == board)
        #expect(board.sortedColumns.count == 1)
    }

    @Test func columnSortOrder() {
        let board = repository.createBoard(name: "Board")
        let col1 = repository.createColumn(in: board, name: "First")
        let col2 = repository.createColumn(in: board, name: "Second")

        #expect(col1.sortOrder < col2.sortOrder)
    }

    @Test func updateColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Original")

        repository.updateColumn(column, name: "Renamed")
        #expect(column.name == "Renamed")
    }

    @Test func deleteColumn() {
        let board = repository.createBoard(name: "Board")
        let column = repository.createColumn(in: board, name: "Col")

        repository.deleteColumn(column)
        #expect(board.sortedColumns.count == 0)
    }

    @Test func reorderBoard() {
        let a = repository.createBoard(name: "A")
        let b = repository.createBoard(name: "B")
        let c = repository.createBoard(name: "C")

        repository.reorderBoard(c, to: 0, in: [a, b, c])

        let boards = repository.fetchAllBoards()
        #expect(boards[0].name == "C")
    }
}
