import CoreData

protocol BoardRepositoryProtocol {
    func fetchAllBoards() -> [Board]
    func createBoard(name: String, colorHex: String?) -> Board
    func updateBoard(_ board: Board, name: String?, colorHex: String?)
    func deleteBoard(_ board: Board)
    func reorderBoard(_ board: Board, to newIndex: Int, in boards: [Board])
    func createColumn(in board: Board, name: String, colorHex: String?) -> Column
    func updateColumn(_ column: Column, name: String?, colorHex: String?)
    func deleteColumn(_ column: Column)
    func reorderColumn(_ column: Column, to newIndex: Int, in columns: [Column])
}

final class BoardRepository: BoardRepositoryProtocol {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchAllBoards() -> [Board] {
        let request = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Board.sortOrder, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func createBoard(name: String, colorHex: String? = nil) -> Board {
        let board = Board(context: context)
        board.id = UUID()
        board.name = name
        board.colorHex = colorHex
        board.createdAt = Date()
        board.modifiedAt = Date()

        let existingBoards = fetchAllBoards()
        let maxSort = existingBoards.last?.sortOrder ?? -1000
        board.sortOrder = maxSort + 1000

        save()
        return board
    }

    func updateBoard(_ board: Board, name: String? = nil, colorHex: String? = nil) {
        if let name = name { board.name = name }
        if let colorHex = colorHex { board.colorHex = colorHex }
        board.modifiedAt = Date()
        save()
    }

    func deleteBoard(_ board: Board) {
        context.delete(board)
        save()
    }

    func reorderBoard(_ board: Board, to newIndex: Int, in boards: [Board]) {
        let newSortOrder = calculateSortOrder(for: newIndex, in: boards.map(\.sortOrder))
        board.sortOrder = newSortOrder
        board.modifiedAt = Date()

        if needsNormalization(boards.map(\.sortOrder), inserting: newSortOrder) {
            normalizeOrder(boards, moving: board, to: newIndex)
        }

        save()
    }

    func createColumn(in board: Board, name: String, colorHex: String? = nil) -> Column {
        let column = Column(context: context)
        column.id = UUID()
        column.name = name
        column.colorHex = colorHex
        column.createdAt = Date()
        column.modifiedAt = Date()
        column.board = board

        let maxSort = board.sortedColumns.last?.sortOrder ?? -1000
        column.sortOrder = maxSort + 1000

        board.modifiedAt = Date()
        save()
        return column
    }

    func updateColumn(_ column: Column, name: String? = nil, colorHex: String? = nil) {
        if let name = name { column.name = name }
        if let colorHex = colorHex { column.colorHex = colorHex }
        column.modifiedAt = Date()
        column.board?.modifiedAt = Date()
        save()
    }

    func deleteColumn(_ column: Column) {
        column.board?.modifiedAt = Date()
        // Fizzy-paired columns leave a tombstone so the deletion propagates
        // to the server on the next sync (issue #12). The cascade delete also
        // removes the column's cards, so paired cards get tombstones too.
        ColumnTombstone.record(for: column, in: context)
        for card in (column.cards as? Set<Card>) ?? [] {
            CardTombstone.record(for: card, in: context)
        }
        context.delete(column)
        save()
    }

    func reorderColumn(_ column: Column, to newIndex: Int, in columns: [Column]) {
        let newSortOrder = calculateSortOrder(for: newIndex, in: columns.map(\.sortOrder))
        column.sortOrder = newSortOrder
        column.modifiedAt = Date()

        if needsNormalization(columns.map(\.sortOrder), inserting: newSortOrder) {
            normalizeColumnOrder(columns, moving: column, to: newIndex)
        }

        save()
    }

    // MARK: - Sort Order Helpers

    private func calculateSortOrder(for index: Int, in sortOrders: [Int32]) -> Int32 {
        if sortOrders.isEmpty { return 0 }
        if index <= 0 { return sortOrders[0] - 1000 }
        if index >= sortOrders.count { return sortOrders[sortOrders.count - 1] + 1000 }

        let before = sortOrders[index - 1]
        let after = sortOrders[index]
        return before + (after - before) / 2
    }

    private func needsNormalization(_ sortOrders: [Int32], inserting newValue: Int32) -> Bool {
        for existing in sortOrders {
            if existing != newValue && abs(existing - newValue) < 2 {
                return true
            }
        }
        return false
    }

    private func normalizeOrder(_ boards: [Board], moving: Board, to index: Int) {
        var ordered = boards.filter { $0.id != moving.id }
        let clampedIndex = min(index, ordered.count)
        ordered.insert(moving, at: clampedIndex)
        for (i, board) in ordered.enumerated() {
            board.sortOrder = Int32(i * 1000)
        }
    }

    private func normalizeColumnOrder(_ columns: [Column], moving: Column, to index: Int) {
        var ordered = columns.filter { $0.id != moving.id }
        let clampedIndex = min(index, ordered.count)
        ordered.insert(moving, at: clampedIndex)
        for (i, column) in ordered.enumerated() {
            column.sortOrder = Int32(i * 1000)
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
