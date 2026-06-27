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
    private let fizzyClient: FizzyClient?
    private let pairingStore: FizzyCardPairingStore
    private var debounceTask: Task<Void, Never>?
    private var observerToken: NSObjectProtocol?

    init(board: Board, context: NSManagedObjectContext, fizzyClient: FizzyClient? = nil, pairingStore: FizzyCardPairingStore = .shared) {
        self.board = board
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        self.cardRepository = CardRepository(context: context)
        self.fizzyClient = fizzyClient
        self.pairingStore = pairingStore
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

    // MARK: - Golden Ticket

    func toggleGolden(for card: Card) {
        card.isGolden.toggle()
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? context.save()
        refreshColumns()
        pushGolden(for: card)
    }

    /// Fire-and-forget push for board-surface golden toggles (context menu,
    /// swipe). The board has no alert affordance, so a failed push reverts
    /// silently — without the push, the next pull reverted it anyway
    /// (#19 wave 3).
    private func pushGolden(for card: Card) {
        let resolved = card.resolvedFizzyNumber(pairingStore)
        guard resolved > 0, let client = fizzyClient else { return }
        let isGolden = card.isGolden
        let number = Int(resolved)
        Task { @MainActor in
            do {
                if isGolden {
                    try await client.markCardGolden(number: number)
                } else {
                    try await client.unmarkCardGolden(number: number)
                }
            } catch {
                // State-recheck: only revert if the card still exists and
                // nothing changed it since.
                if !card.isDeleted, card.managedObjectContext != nil,
                   card.isGolden == isGolden {
                    card.isGolden = !isGolden
                    card.modifiedAt = Date()
                    try? self.context.save()
                    self.refreshColumns()
                }
            }
        }
    }

    func toggleGolden(cardID: UUID) {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", cardID as CVarArg)
        request.fetchLimit = 1
        guard let card = try? context.fetch(request).first else { return }
        toggleGolden(for: card)
    }

    // MARK: - Lifecycle actions (board-surface context menu / swipe)

    /// Fire-and-forget lifecycle action from a board-surface control (context
    /// menu). The board has no alert surface; a failed push reverts silently —
    /// the next pull is reconciler of last resort (#19 pattern).
    func performLifecycleAction(_ action: CardLifecycleAction, on card: Card) {
        Task { @MainActor in
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
            let previous = card.lifecycleStatus
            let targetStatus: CardLifecycleStatus
            switch action {
            case .close: targetStatus = .closed
            case .reopen: targetStatus = .active
            case .postpone: targetStatus = .notNow
            }
            card.lifecycleStatus = targetStatus
            card.modifiedAt = Date()
            card.column?.modifiedAt = Date()
            card.column?.board?.modifiedAt = Date()
            try? context.save()
            refreshColumns()

            let resolved = card.resolvedFizzyNumber(pairingStore)
            guard resolved > 0, let client = fizzyClient else { return }
            let number = Int(resolved)
            do {
                switch action {
                case .close:
                    try await client.closeCard(number: number)
                case .reopen:
                    try await client.reopenCard(number: number)
                case .postpone:
                    try await client.postponeCard(number: number)
                }
            } catch {
                // State-recheck revert (fire-and-forget, no alert surface on board)
                if !card.isDeleted, card.managedObjectContext != nil,
                   card.lifecycleStatus == targetStatus {
                    card.lifecycleStatus = previous
                    card.modifiedAt = Date()
                    try? context.save()
                    refreshColumns()
                }
            }
        }
    }

    // MARK: - Lifecycle filter (#34 default A)

    /// Per-board UserDefaults key — encodes the board's stable CoreData
    /// object URI so each board remembers its own toggle independently (#13/#34).
    private var showClosedKey: String {
        "showClosedCards.\(board.objectID.uriRepresentation().absoluteString)"
    }

    /// Board-level toggle — persisted per-board via a board-scoped UserDefaults
    /// key so navigating between boards does not bleed toggle state. @AppStorage
    /// cannot be a stored property on a non-View type, so we proxy through a
    /// computed property backed by UserDefaults directly.
    var showClosedCards: Bool {
        get { UserDefaults.standard.bool(forKey: showClosedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: showClosedKey)
            objectWillChange.send()
        }
    }

    /// Returns the cards that should be visible in `column` given the current
    /// `showClosed` preference. Active cards are always shown; closed/notNow
    /// are hidden by default and visible when the toggle is on.
    func visibleCards(in column: Column, showClosed: Bool) -> [Card] {
        column.sortedCards.filter { card in
            switch card.lifecycleStatus {
            case .active:
                return true
            case .closed, .notNow:
                return showClosed
            }
        }
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
