import CoreData
import SwiftUI
import Combine

final class BoardViewModel: ObservableObject {
    @Published var board: Board
    @Published var columns: [Column] = []
    @Published var selectedColumnIndex: Int = 0
    @Published var selectedColumnForNewCard: Column?

    private let boardRepository: BoardRepository
    private let cardRepository: CardRepository
    private let context: NSManagedObjectContext
    private var debounceTask: Task<Void, Never>?
    private var observerToken: NSObjectProtocol?

    init(board: Board, context: NSManagedObjectContext) {
        self.board = board
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        self.cardRepository = CardRepository(context: context)
        refreshColumns()
        observeChanges()
    }
    
    deinit {
        debounceTask?.cancel()
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshColumns() {
        columns = board.sortedColumns
    }

    // MARK: - Column Operations

    func addColumn(name: String, colorHex: String? = nil) {
        _ = boardRepository.createColumn(in: board, name: name, colorHex: colorHex)
        refreshColumns()
    }

    func deleteColumn(_ column: Column) {
        boardRepository.deleteColumn(column)
        refreshColumns()
        if selectedColumnIndex >= columns.count {
            selectedColumnIndex = max(0, columns.count - 1)
        }
    }

    func updateColumn(_ column: Column, name: String? = nil, colorHex: String? = nil) {
        boardRepository.updateColumn(column, name: name, colorHex: colorHex)
        refreshColumns()
    }

    // MARK: - Card Operations

    func addCard(to column: Column, title: String) {
        _ = cardRepository.createCard(in: column, title: title)
        refreshColumns()
    }

    func deleteCard(_ card: Card) {
        cardRepository.deleteCard(card)
        refreshColumns()
    }

    func moveCardUp(_ card: Card) {
        cardRepository.moveCardUp(card)
        refreshColumns()
    }

    func moveCardDown(_ card: Card) {
        cardRepository.moveCardDown(card)
        refreshColumns()
    }

    // MARK: - Drag & Drop

    func moveCard(_ cardID: UUID, to column: Column, at index: Int) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s debounce
            guard !Task.isCancelled else { return }
            self.performMoveCard(cardID, to: column, at: index)
        }
    }

    private func performMoveCard(_ cardID: UUID, to column: Column, at index: Int) {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", cardID as CVarArg)
        guard let card = (try? context.fetch(request))?.first else { return }

        if card.column == column {
            cardRepository.reorderCard(card, to: index, in: column.sortedCards)
        } else {
            cardRepository.moveCard(card, to: column, at: index)
        }
        refreshColumns()
    }

    func reorderCard(_ card: Card, to index: Int, in column: Column) {
        cardRepository.reorderCard(card, to: index, in: column.sortedCards)
        refreshColumns()
    }

    private func observeChanges() {
        observerToken = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshColumns()
        }
    }
}
