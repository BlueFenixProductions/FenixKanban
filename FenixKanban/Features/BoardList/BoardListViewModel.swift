import CoreData
import SwiftUI

final class BoardListViewModel: ObservableObject {
    @Published var boards: [Board] = []
    @Published var showNewBoardSheet = false

    private let boardRepository: BoardRepository
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        fetchBoards()
        observeChanges()
    }

    func fetchBoards() {
        boards = boardRepository.fetchAllBoards()
    }

    func createBoard(name: String, colorHex: String?) {
        _ = boardRepository.createBoard(name: name, colorHex: colorHex)
        fetchBoards()
    }

    func deleteBoard(_ board: Board) {
        boardRepository.deleteBoard(board)
        fetchBoards()
    }

    func deleteBoards(at offsets: IndexSet) {
        for index in offsets {
            boardRepository.deleteBoard(boards[index])
        }
        fetchBoards()
    }

    func moveBoard(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        let board = boards[sourceIndex]
        boardRepository.reorderBoard(board, to: destination, in: boards)
        fetchBoards()
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchBoards()
        }
    }
}
