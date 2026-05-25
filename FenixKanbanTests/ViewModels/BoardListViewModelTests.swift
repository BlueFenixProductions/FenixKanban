import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BoardList ViewModel", .serialized)
@MainActor
struct BoardListViewModelTests {
    let persistence: PersistenceController
    let viewModel: BoardListViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        viewModel = BoardListViewModel(context: persistence.viewContext)
    }

    @Test func initiallyEmpty() {
        #expect(viewModel.boards.isEmpty)
    }

    @Test func createBoard() {
        viewModel.createBoard(name: "Test", colorHex: "#FF0000")
        #expect(viewModel.boards.count == 1)
        #expect(viewModel.boards[0].name == "Test")
    }

    @Test func deleteBoard() {
        viewModel.createBoard(name: "ToDelete", colorHex: nil)
        #expect(viewModel.boards.count == 1)

        viewModel.deleteBoard(viewModel.boards[0])
        #expect(viewModel.boards.count == 0)
    }

    @Test func deleteBoardsAtOffsets() {
        viewModel.createBoard(name: "A", colorHex: nil)
        viewModel.createBoard(name: "B", colorHex: nil)
        viewModel.createBoard(name: "C", colorHex: nil)

        viewModel.deleteBoards(at: IndexSet(integer: 1))
        #expect(viewModel.boards.count == 2)
        #expect(viewModel.boards[0].name == "A")
        #expect(viewModel.boards[1].name == "C")
    }
}
