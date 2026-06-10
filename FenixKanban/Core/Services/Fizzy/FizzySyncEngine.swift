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

    /// Reentrancy guard. `sync()`/`syncFirst(mode:)` suspend at every HTTP
    /// await, so a second call (double-tapped Sync Now, a pair-then-sync
    /// overlap, or Phase 6's polling timer) could interleave with the first,
    /// snapshot the same nil-`fizzyID` cards, and POST them twice — the
    /// UAT "~40 duplicate cards" bug. While a run is in flight, subsequent
    /// calls return an empty `FizzySyncResult` immediately.
    private var isSyncing = false

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
        guard !isSyncing else { return FizzySyncResult() }
        isSyncing = true
        defer { isSyncing = false }
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

    /// Steady-state sync. Runs the pull/push/LWW/soft-delete cycle. Caller
    /// must have completed `syncFirst(mode:)` once before — `sync()` keys off
    /// `Card.fizzyID` and won't pair anything by title.
    ///
    /// Returns an empty `FizzySyncResult` if the engine is unpaired.
    /// Records `mapping.setLastSync(.now)` at the end of every successful cycle.
    func sync() async throws -> FizzySyncResult {
        guard !isSyncing else { return FizzySyncResult() }
        isSyncing = true
        defer { isSyncing = false }
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return FizzySyncResult()
        }
        do {
            return try await steadyStateSync(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        } catch FizzyError.unauthorized {
            // Token revoked or expired — clear Keychain entries so Phase 5's
            // UI can prompt re-auth.
            authState.clear()
            throw FizzyError.unauthorized
        }
    }

    private func steadyStateSync(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        var result = FizzySyncResult()

        // Fetch remote state.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        // Local cards keyed by fizzyID (only paired ones).
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { col -> [Card] in
            (col.cards as? Set<Card>).map { Array($0) } ?? []
        }
        let pairedByFizzyID: [String: Card] = Dictionary(
            uniqueKeysWithValues: localCards.compactMap { card in card.fizzyID.map { ($0, card) } }
        )

        // Resolve columns: auto-create local for any remote name not seen.
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let new = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = new
            }
        }

        // Crash-after-POST recovery: precompute orphan claims so the pull loop
        // doesn't also create a duplicate from the same remote. For each local
        // card with nil fizzyID, try to find an unpaired remote with matching
        // title + createdAt within ±60s. First-match wins; each remote is
        // claimed by at most one local.
        let orphanWindow: TimeInterval = 60
        var orphansByLocalID: [NSManagedObjectID: String] = [:]
        var claimedRemoteIDs: Set<String> = []
        for card in localCards where card.fizzyID == nil {
            let localCreated = card.createdAt ?? .distantPast
            let orphan = remoteCards.first { remote in
                remote.title == (card.title ?? "")
                    && abs(remote.createdAt.timeIntervalSince(localCreated)) <= orphanWindow
                    && pairedByFizzyID[remote.id] == nil
                    && !claimedRemoteIDs.contains(remote.id)
            }
            if let orphan {
                orphansByLocalID[card.objectID] = orphan.id
                claimedRemoteIDs.insert(orphan.id)
            }
        }

        // Pull: for each remote card not yet paired locally AND not earmarked
        // for an orphan claim, create it.
        for remote in remoteCards
        where pairedByFizzyID[remote.id] == nil && !claimedRemoteIDs.contains(remote.id) {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)
            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // LWW for paired cards (both sides have fizzyID).
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        for (fizzyID, card) in pairedByFizzyID {
            guard let remote = remoteByID[fizzyID] else { continue }
            // Backfill the card number — Fizzy addresses per-card routes by
            // `number`, not the opaque `id` (the server does
            // `find_by!(number: params[:id])`). Cards paired before this
            // attribute existed self-heal here on their next sync.
            if card.fizzyNumber == 0 { card.fizzyNumber = Int64(remote.number) }
            let localFizzyTimestamp = card.fizzyUpdatedAt ?? .distantPast
            let localModified = card.modifiedAt ?? .distantPast
            let remoteTimestamp = remote.lastActiveAt

            if remoteTimestamp > localFizzyTimestamp && localModified <= localFizzyTimestamp {
                // Remote newer, local untouched → pull.
                applyRemote(remote, to: card)
                result.itemsUpdated += 1
            } else if localModified > localFizzyTimestamp {
                // Local edited since last sync → push.
                do {
                    let updated = try await putCard(card, number: card.fizzyNumber)
                    card.fizzyUpdatedAt = updated.lastActiveAt
                    card.modifiedAt = updated.lastActiveAt
                    result.itemsUpdated += 1
                } catch let error as FizzyError {
                    result.errors.append("Push update '\(card.title ?? "(untitled)")': \(error)")
                }
            }
            // else: both equal or remote stale → no-op.
        }

        // Soft-delete: paired local cards whose fizzyID is no longer in the
        // remote response were deleted on the server.
        for (fizzyID, card) in pairedByFizzyID where remoteByID[fizzyID] == nil {
            context.delete(card)
            result.itemsDeleted += 1
        }

        // Push: local cards with nil fizzyID (not yet paired) → claim a
        // precomputed orphan or POST a new card.
        for card in localCards where card.fizzyID == nil {
            if let orphanID = orphansByLocalID[card.objectID],
               let orphan = remoteByID[orphanID] {
                card.fizzyID = orphan.id
                card.fizzyNumber = Int64(orphan.number)
                card.fizzyUpdatedAt = orphan.lastActiveAt
                card.modifiedAt = orphan.lastActiveAt
                result.itemsUpdated += 1
                continue
            }
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyNumber = Int64(created.number)
                card.fizzyUpdatedAt = created.lastActiveAt
                card.modifiedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        // Persist lastSyncAt.
        mapping.setLastSync(.now)

        if context.hasChanges {
            try context.save()
        }
        return result
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
                card.fizzyNumber = Int64(created.number)
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
                card.fizzyNumber = Int64(created.number)
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
        try await client.getAllPages("/boards/\(boardID)/columns", as: [FizzyColumn].self)
    }

    /// Fetches all cards for a remote board via the per-board list endpoint
    /// `GET /:account/cards?board_ids[]=<id>`. Phase 4a uses the list shape
    /// (no `column` field per Fizzy docs) — column placement is recovered
    /// from each card's column relationship on a follow-up GET if needed.
    /// For the first-sync modes we accept "no column" → drop into the
    /// first available column.
    private func fetchRemoteCards(boardID: String) async throws -> [FizzyCard] {
        try await client.getAllPages("/cards?board_ids[]=\(boardID)", as: [FizzyCard].self)
    }

    // MARK: - Apply remote → local

    /// Writes the synced fields from a `FizzyCard` onto a local `Card`.
    /// Phase 4a maps only the first remote tag to `Card.label`; remaining
    /// tags are dropped (documented limitation).
    ///
    /// `modifiedAt` is reset to `fizzyUpdatedAt` so the next steady-state LWW
    /// check sees "local untouched since last sync" and doesn't spuriously
    /// re-push. Steady-state convergence depends on this.
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        card.cardDescription = remote.description
        card.isGolden = remote.golden
        card.fizzyID = remote.id
        card.fizzyNumber = Int64(remote.number)
        card.fizzyUpdatedAt = remote.lastActiveAt
        card.modifiedAt = remote.lastActiveAt

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

    /// PUT an updated local card to the remote. Returns the updated FizzyCard
    /// so we can sync back the server's lastActiveAt.
    private func putCard(_ card: Card, number: Int64) async throws -> FizzyCard {
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: card.cardDescription,
                status: nil,
                tagIds: nil
            )
        )
        return try await client.put(
            "/cards/\(number)",
            body: payload,
            as: FizzyCard.self
        )
    }

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
