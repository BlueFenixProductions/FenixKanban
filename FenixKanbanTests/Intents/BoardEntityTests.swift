import Testing
import CoreData
@testable import FenixKanban

@Suite("Board Entity", .serialized)
@MainActor
struct BoardEntityTests {

    private func makeRepo() -> (PersistenceController, BoardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        return (persistence, repo)
    }

    @Test func initFromBoardPopulatesFields() throws {
        let (_, repo) = makeRepo()
        let board = repo.createBoard(name: "Bug Triage", colorHex: "#E94560")

        let entity = try BoardEntity(from: board)

        #expect(entity.id == board.id)
        #expect(entity.name == "Bug Triage")
        #expect(entity.colorHex == "#E94560")
    }

    @Test func initFromBoardThrowsWhenIdMissing() {
        let (persistence, _) = makeRepo()
        let board = Board(context: persistence.viewContext)
        board.name = "No-ID Board"

        #expect(throws: (any Error).self) {
            try BoardEntity(from: board)
        }
    }

    @Test func displayRepresentationUsesName() throws {
        let (_, repo) = makeRepo()
        let board = repo.createBoard(name: "Bug Triage")

        let entity = try BoardEntity(from: board)

        #expect(String(describing: entity.displayRepresentation).contains("Bug Triage"))
    }

    @Test func queryByIDReturnsMatchingBoards() async throws {
        let (persistence, repo) = makeRepo()
        let board1 = repo.createBoard(name: "One")
        let board2 = repo.createBoard(name: "Two")
        let uuid1 = try #require(board1.id)
        let uuid2 = try #require(board2.id)

        let query = BoardQuery(context: persistence.viewContext)
        let results = try await query.entities(for: [uuid1, uuid2])

        let names = Set(results.map(\.name))
        #expect(names == ["One", "Two"])
    }

    @Test func suggestedEntitiesReturnsAllBoardsSorted() async throws {
        let (persistence, repo) = makeRepo()
        _ = repo.createBoard(name: "Charlie")
        _ = repo.createBoard(name: "Alpha")
        _ = repo.createBoard(name: "Bravo")

        let query = BoardQuery(context: persistence.viewContext)
        let results = try await query.suggestedEntities()

        #expect(results.map(\.name) == ["Alpha", "Bravo", "Charlie"])
    }
}
