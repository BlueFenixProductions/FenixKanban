import Foundation
import CoreData

/// Orchestrates one-shot first-sync runs between a paired local FenixKanban
/// board and the corresponding Fizzy board.
///
/// Composition is deliberate: the engine owns no Keychain or UserDefaults
/// access of its own — it consumes the Phase 2 `FizzyAuthState` and
/// `FizzyBoardMapping` instances injected at construction. Likewise, all
/// HTTP goes through `FizzyClient`. This keeps the engine fully testable
/// with `MockURLProtocol` and synthetic auth/mapping fixtures.
///
/// Phase 4a covers the three `FirstSyncMode` variants only. Steady-state
/// diff + LWW conflict resolution + soft-delete + 401 handling land in
/// Phase 4b.
@MainActor
final class FizzySyncEngine {

    private let client: FizzyClient
    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let context: NSManagedObjectContext

    init(
        client: FizzyClient,
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        context: NSManagedObjectContext
    ) {
        self.client = client
        self.authState = authState
        self.mapping = mapping
        self.context = context
    }

    /// One-shot first-sync. Caller must have set `authState.accessToken`,
    /// `authState.accountSlug`, `mapping.setPairing(...)` *before* invoking.
    /// Returns an empty `FizzySyncResult` if any of those are missing.
    func syncFirst(mode: FirstSyncMode) async throws -> FizzySyncResult {
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return FizzySyncResult()
        }

        switch mode {
        case .pushLocalToFizzy:
            return try await syncFirstPushLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .replaceLocalWithFizzy:
            return try await syncFirstReplaceLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .mergeIfNoConflicts:
            return try await syncFirstMerge(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        }
    }

    // MARK: - Mode implementations (skeleton — return empty in this task; filled by Tasks 4-6)

    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        // Push mode: POST every local card on the paired board. We don't
        // pull anything from remote in Phase 4a — pre-existing remote cards
        // (if any) stay untouched and become local cards in Phase 4b's
        // steady-state sync.
        var result = FizzySyncResult()
        let columns = (localBoard.columns as? Set<Column>) ?? Set<Column>()
        let cards: [Card] = columns.flatMap { column in
            (column.cards as? Set<Card>) ?? Set<Card>()
        }

        for card in cards where card.fizzyID == nil {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }

    private func syncFirstReplaceLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        var result = FizzySyncResult()

        // 1. Wipe local cards on the paired board.
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { column -> [Card] in
            (column.cards as? Set<Card>).map { Array($0) } ?? []
        }
        for card in localCards {
            context.delete(card)
            result.itemsDeleted += 1
        }

        // 2. Pull remote columns + cards.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        // 3. Auto-create local columns for any remote name not seen.
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let newColumn = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = newColumn
            }
        }

        // 4. Create local cards mirroring each remote.
        for remote in remoteCards {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)

            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }

    private func syncFirstMerge(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        var result = FizzySyncResult()

        // Fetch both sides.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { column -> [Card] in
            (column.cards as? Set<Card>).map { Array($0) } ?? []
        }

        // Lower-cased title sets for collision detection.
        let localTitleMap: [String: String] = Dictionary(
            localCards.compactMap { card -> (String, String)? in
                guard let title = card.title else { return nil }
                return (title.lowercased(), title)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let localTitles = Set(localTitleMap.keys)
        let remoteTitlesLower = Set(remoteCards.map { $0.title.lowercased() })

        // Collisions = title appears on BOTH sides. Skipped entirely (neither side touched).
        let collisions = localTitles.intersection(remoteTitlesLower)
        for collidingTitleLower in collisions {
            let displayTitle = localTitleMap[collidingTitleLower] ?? collidingTitleLower
            result.errors.append("Same-title collision: '\(displayTitle)'")
        }

        // Auto-create local columns for any remote name not seen (so we have somewhere to drop pulls).
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let newColumn = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = newColumn
            }
        }

        // Pull remote-only cards (not in local, not a collision).
        for remote in remoteCards where !localTitles.contains(remote.title.lowercased()) {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)
            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // Push local-only cards (nil fizzyID, not a collision).
        for card in localCards where card.fizzyID == nil
                                && !remoteTitlesLower.contains(card.title?.lowercased() ?? "") {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }

    // MARK: - Remote fetches

    private func fetchRemoteColumns(boardID: String) async throws -> [FizzyColumn] {
        try await client.get("/boards/\(boardID)/columns", as: [FizzyColumn].self)
    }

    /// Fetches all cards for a remote board via the per-board list endpoint
    /// `GET /:account/cards?board_ids[]=<id>`. Phase 4a uses the list shape
    /// (no `column` field per Fizzy docs) — column placement is recovered
    /// from each card's column relationship on a follow-up GET if needed.
    /// For the first-sync modes we accept "no column" → drop into the
    /// first available column.
    private func fetchRemoteCards(boardID: String) async throws -> [FizzyCard] {
        try await client.get("/cards?board_ids[]=\(boardID)", as: [FizzyCard].self)
    }

    // MARK: - Apply remote → local

    /// Writes the synced fields from a `FizzyCard` onto a local `Card`.
    /// Phase 4a maps only the first remote tag to `Card.label`; remaining
    /// tags are dropped (documented limitation).
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        card.cardDescription = remote.description
        card.isGolden = remote.golden
        card.fizzyID = remote.id
        card.fizzyUpdatedAt = remote.lastActiveAt

        if let firstTag = remote.tags.first {
            card.label = findOrCreateLabel(name: firstTag)
        } else {
            card.label = nil
        }
    }

    /// Finds a `Label` by case-insensitive name or creates one with a
    /// deterministic color derived from the name.
    private func findOrCreateLabel(name: String) -> Label {
        let request: NSFetchRequest<Label> = Label.fetchRequest()
        request.predicate = NSPredicate(format: "name ==[c] %@", name)
        request.fetchLimit = 1
        if let existing = (try? context.fetch(request))?.first {
            return existing
        }
        let colorHex = FizzySyncMapping.labelColorHex(forName: name)
        return LabelRepository(context: context).createLabel(name: name, colorHex: colorHex)
    }

    // MARK: - Card writes

    /// POSTs a local card to the remote board and returns the resulting
    /// `FizzyCard` (the client follows Location to fetch the full record).
    ///
    /// Phase 4a does not push `tag_ids` — see "Important spec divergences"
    /// in the plan. The Fizzy API treats `tag_ids` as optional; omitting it
    /// preserves whatever tags the server defaults to (none, for new cards).
    private func postCard(_ card: Card, toBoardID fizzyBoardID: String) async throws -> FizzyCard {
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: card.cardDescription,
                status: nil,
                tagIds: nil
            )
        )
        return try await client.post(
            "/boards/\(fizzyBoardID)/cards",
            body: payload,
            as: FizzyCard.self
        )
    }

    // MARK: - Lookups

    /// Fetches a local `Board` by its UUID (the form stored in
    /// `FizzyBoardMapping`). Returns `nil` if the board was deleted.
    private func fetchBoard(by id: UUID) -> Board? {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
