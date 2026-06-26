import Testing
import CoreData
@testable import FenixKanban

@Suite("BoardViewModel showClosedCards per-board isolation", .serialized)
@MainActor
struct BoardViewModelShowClosedTests {

    private func makeContext() -> (PersistenceController, BoardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        return (persistence, repo)
    }

    @Test func defaultsToFalse() {
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Board A")
        let vm = BoardViewModel(board: board, context: persistence.viewContext)
        #expect(vm.showClosedCards == false)
    }

    @Test func toggleOnBoardADoesNotAffectBoardB() {
        let (persistence, repo) = makeContext()
        let boardA = repo.createBoard(name: "Board A")
        let boardB = repo.createBoard(name: "Board B")
        let vmA = BoardViewModel(board: boardA, context: persistence.viewContext)
        let vmB = BoardViewModel(board: boardB, context: persistence.viewContext)

        // Verify both start false
        #expect(vmA.showClosedCards == false)
        #expect(vmB.showClosedCards == false)

        // Toggle board A on
        vmA.showClosedCards = true

        // Board A is on, Board B must remain off
        #expect(vmA.showClosedCards == true)
        #expect(vmB.showClosedCards == false)
    }

    @Test func toggleOnBoardBDoesNotAffectBoardA() {
        let (persistence, repo) = makeContext()
        let boardA = repo.createBoard(name: "Board A")
        let boardB = repo.createBoard(name: "Board B")
        let vmA = BoardViewModel(board: boardA, context: persistence.viewContext)
        let vmB = BoardViewModel(board: boardB, context: persistence.viewContext)

        vmB.showClosedCards = true

        #expect(vmB.showClosedCards == true)
        #expect(vmA.showClosedCards == false)
    }

    @Test func statePersistedAcrossViewModelRecreation() {
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Board A")

        let vmFirst = BoardViewModel(board: board, context: persistence.viewContext)
        vmFirst.showClosedCards = true

        // Recreate the view model (simulates navigation away and back)
        let vmSecond = BoardViewModel(board: board, context: persistence.viewContext)
        #expect(vmSecond.showClosedCards == true)
    }
}
