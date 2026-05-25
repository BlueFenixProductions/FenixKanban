import Testing
import CoreData
@testable import FenixKanban

@Suite("BoardViewModel Lifecycle", .serialized)
@MainActor
struct BoardViewModelLifecycleTests {

    private func makeContext() -> (PersistenceController, BoardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        return (persistence, repo)
    }

    @Test func initialStateAfterInit() {
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Test Board")
        let viewModel = BoardViewModel(board: board, context: persistence.viewContext)

        #expect(viewModel.board.id == board.id)
        #expect(viewModel.columns.isEmpty)
        #expect(viewModel.selectedColumnIndex == 0)
    }

    @Test func updateColumnRenamesAndRecolorsTogether() {
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Test Board")
        let viewModel = BoardViewModel(board: board, context: persistence.viewContext)
        viewModel.addColumn(name: "Original", colorHex: "#FF0000")

        viewModel.updateColumn(viewModel.columns[0], name: "Updated", colorHex: "#00FF00")

        #expect(viewModel.columns[0].name == "Updated")
        #expect(viewModel.columns[0].colorHex == "#00FF00")
    }

    @Test func deleteColumnAdjustsSelectionWhenLastIsRemoved() {
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Test Board")
        let viewModel = BoardViewModel(board: board, context: persistence.viewContext)
        viewModel.addColumn(name: "Col 1")
        viewModel.addColumn(name: "Col 2")
        viewModel.addColumn(name: "Col 3")

        viewModel.selectedColumnIndex = 2
        viewModel.deleteColumn(viewModel.columns[2])

        #expect(viewModel.selectedColumnIndex <= viewModel.columns.count - 1)
        #expect(viewModel.columns.count == 2)
    }

    @Test func viewModelDeallocatesCleanly() async {
        // The init() registers an NSManagedObjectContextDidSave observer; the
        // matching deinit must remove it. If the observer closure retained
        // self (instead of using [weak self]), the weak reference below would
        // still be non-nil after we drop our strong reference.
        let (persistence, repo) = makeContext()
        let board = repo.createBoard(name: "Test Board")
        weak var weakViewModel: BoardViewModel?
        autoreleasepool {
            let viewModel = BoardViewModel(board: board, context: persistence.viewContext)
            weakViewModel = viewModel
            _ = viewModel  // ensure live until end of scope
        }
        // Yield to let any pending autorelease drains complete.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(weakViewModel == nil, "BoardViewModel should deallocate after its sole strong reference is dropped")
    }
}
