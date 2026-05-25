import Testing
import AppIntents
import CoreData
@testable import FenixKanban

@Suite("Open Board Intent", .serialized)
@MainActor
struct OpenBoardIntentTests {

    private func setup() -> (PersistenceController, BoardRepository, NavigationModel) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        let navigator = NavigationModel()
        return (persistence, repo, navigator)
    }

    @Test func performSelectsBoardOnNavigator() async throws {
        let (persistence, repo, navigator) = setup()
        let board = repo.createBoard(name: "Bug Triage")
        let entity = try BoardEntity(from: board)

        var intent = OpenBoardIntent()
        intent.board = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        _ = try await intent.perform()

        #expect(navigator.selectedBoardID == board.objectID)
    }

    @Test func performThrowsWhenBoardNoLongerExists() async throws {
        let (persistence, _, navigator) = setup()
        let entity = BoardEntity(id: UUID(), name: "Ghost", colorHex: nil)

        var intent = OpenBoardIntent()
        intent.board = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            try await intent.perform()
        }
        #expect(navigator.selectedBoardID == nil)
    }
}
