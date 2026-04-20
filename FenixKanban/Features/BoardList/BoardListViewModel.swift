import CoreData
import SwiftUI

final class BoardListViewModel: ObservableObject {
    @Published var boards: [Board] = []

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

    func updateBoard(_ board: Board, name: String? = nil, colorHex: String? = nil) {
        boardRepository.updateBoard(board, name: name, colorHex: colorHex)
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
        // NSManagedObjectContextObjectsDidChange fires for both local saves and CloudKit
        // remote merges (which don't trigger DidSave on the view context). Filtering to
        // Board/Column/Card keeps this from firing on unrelated in-memory mutations.
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] notification in
            self?.handleContextObjectsChange(notification)
        }
    }

    private func handleContextObjectsChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
            .compactMap { userInfo[$0] as? Set<NSManagedObject> }
            .reduce(Set<NSManagedObject>()) { $0.union($1) }

        guard changed.contains(where: { $0 is Board || $0 is Column || $0 is Card }) else { return }

        // When cards arrive via CloudKit sync, only Card/Column objectWillChange fires —
        // Board's doesn't, so @ObservedObject in BoardRowView never re-renders. Nudge it.
        for obj in changed {
            if let card = obj as? Card, let board = card.column?.board {
                board.objectWillChange.send()
            }
        }

        fetchBoards()
    }
}
