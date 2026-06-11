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

        // Push local deletions FIRST — before any pull — so a card/column the
        // user deleted locally can't be resurrected by the very same cycle
        // (issues #11/#12, "delete wins").
        await pushCardDeletions(into: &result)
        await pushColumnDeletions(localBoard: localBoard, fizzyBoardID: fizzyBoardID, into: &result)

        // Tombstones that survived the push (failed DELETEs awaiting retry)
        // block pull-resurrection below.
        let blockedCardNumbers = Set(fetchCardTombstones().map(\.fizzyNumber))
        let blockedColumnIDs = Set(fetchColumnTombstones().compactMap(\.fizzyColumnID))

        // Fetch remote state.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)

        // Reconcile columns (pair by fizzyColumnID, backfill by name, push
        // local creates/renames) and build the name-keyed placement map used
        // by the card pull below.
        let resolvedColumns = await reconcileColumns(
            localBoard: localBoard,
            fizzyBoardID: fizzyBoardID,
            remoteColumns: remoteColumns,
            blockedColumnIDs: blockedColumnIDs,
            into: &result
        )

        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        // Local cards keyed by fizzyID (only paired ones).
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { col -> [Card] in
            (col.cards as? Set<Card>).map { Array($0) } ?? []
        }
        var pairedByFizzyID: [String: Card] = Dictionary(
            uniqueKeysWithValues: localCards.compactMap { card in card.fizzyID.map { ($0, card) } }
        )

        // Clobber recovery (issue #15): a CloudKit merge can null out
        // `fizzyID` while `fizzyNumber` survives. Re-pair by number instead
        // of treating the card as new (which would duplicate it both ways).
        let remoteByNumber: [Int64: FizzyCard] = Dictionary(
            remoteCards.map { (Int64($0.number), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for card in localCards where card.fizzyID == nil && card.fizzyNumber != 0 {
            guard let remote = remoteByNumber[card.fizzyNumber],
                  pairedByFizzyID[remote.id] == nil else { continue }
            card.fizzyID = remote.id
            pairedByFizzyID[remote.id] = card
            result.itemsUpdated += 1
        }

        // Marker-based deterministic adoption (issue #14): every POSTed
        // description carries a hidden `<!--fk:LOCAL_UUID-->` marker. If a
        // remote card's marker names a local unpaired card, that card is the
        // owner — adopt it BEFORE the fuzzy title±60s heuristic gets a say.
        // The marker stays on the remote by design — see putCard (issue #21).
        let unpairedByLocalUUID: [UUID: Card] = Dictionary(
            localCards.compactMap { card -> (UUID, Card)? in
                guard card.fizzyID == nil, let id = card.id else { return nil }
                return (id, card)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for remote in remoteCards
        where pairedByFizzyID[remote.id] == nil
            && !blockedCardNumbers.contains(Int64(remote.number)) {
            guard let ownerID = Self.adoptionMarkerUUID(in: remote.description),
                  let owner = unpairedByLocalUUID[ownerID],
                  owner.fizzyID == nil
            else { continue }
            owner.fizzyID = remote.id
            owner.fizzyNumber = Int64(remote.number)
            owner.fizzyUpdatedAt = remote.lastActiveAt
            owner.modifiedAt = remote.lastActiveAt
            pairedByFizzyID[remote.id] = owner
            result.itemsUpdated += 1
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
        // for an orphan claim AND not locally tombstoned (delete wins — a
        // pending deletion must not resurrect), create it.
        for remote in remoteCards
        where pairedByFizzyID[remote.id] == nil
            && !claimedRemoteIDs.contains(remote.id)
            && !blockedCardNumbers.contains(Int64(remote.number)) {
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
                // Local edited since last sync → push. putCard re-embeds the
                // adoption marker so it survives the edit (issue #21).
                do {
                    let updated = try await putCard(card, number: card.fizzyNumber)
                    card.fizzyUpdatedAt = updated.lastActiveAt
                    card.modifiedAt = updated.lastActiveAt
                    result.itemsUpdated += 1
                } catch let error as FizzyError {
                    result.errors.append("Push update '\(card.title ?? "(untitled)")': \(error)")
                }
            }
            // else: both equal or remote stale → no-op. Any adoption marker
            // in the remote description is deliberately left in place —
            // markers persist remotely by design (issue #21).
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

        // Pin reconciliation (issue #19 wave 3): pins are user-scoped and
        // account-wide; the card wire shape never carries pinned state, so
        // GET /my/pins is the only source of truth. Best-effort — a failed
        // fetch leaves local pin state alone rather than failing the sync.
        await reconcilePins(localBoard: localBoard)

        // Persist lastSyncAt.
        mapping.setLastSync(.now)

        // A failed save must surface — not throw away the whole result and
        // not pass silently (issue #15). The next sync re-pairs any cards
        // whose POSTed pairing was lost via the #14 adoption marker, so a
        // save failure here cannot cause duplicate POSTs.
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                result.errors.append("Save: \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Pin reconciliation (issue #19 wave 3)

    /// Sets `isPinned` on every paired card to match `GET /my/pins`
    /// (remote-authoritative, Captain's ruling #19 wave 3). Deliberately
    /// does NOT bump modifiedAt: pin state is not part of the card-content
    /// LWW contract and must not trigger echo-PUTs.
    private func reconcilePins(localBoard: Board) async {
        guard let pins = try? await client.myPins() else { return }
        let pinnedIDs = Set(pins.map(\.id))
        for column in localBoard.sortedColumns {
            for card in column.sortedCards {
                guard let fizzyID = card.fizzyID else { continue }
                let shouldPin = pinnedIDs.contains(fizzyID)
                if card.isPinned != shouldPin {
                    card.isPinned = shouldPin
                }
            }
        }
    }

    // MARK: - Adoption marker (issue #14)

    /// Hidden HTML-comment marker appended to every POSTed description:
    /// `<!--fk:LOCAL_UUID-->`. Fizzy renders HTML comments invisibly, and the
    /// marker survives crash-after-POST / save failures, letting the next
    /// pull adopt the remote card deterministically instead of relying on the
    /// title±60s heuristic (or worse, re-POSTing a duplicate).
    nonisolated static func adoptionMarker(for localID: UUID) -> String {
        "<!--fk:\(localID.uuidString)-->"
    }

    private nonisolated static let adoptionMarkerPattern =
        #"<!--fk:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-->"#

    /// Extracts the local-card UUID from the first adoption marker in a
    /// remote description, if any.
    nonisolated static func adoptionMarkerUUID(in description: String?) -> UUID? {
        guard let description,
              let range = description.range(of: adoptionMarkerPattern, options: .regularExpression)
        else { return nil }
        let uuidString = description[range].dropFirst("<!--fk:".count).dropLast("-->".count)
        return UUID(uuidString: String(uuidString))
    }

    /// Removes all adoption markers (and the `\n\n` separator that precedes
    /// them when appended to a non-empty description). Local copies never
    /// contain markers — applied in every pull path.
    nonisolated static func strippingAdoptionMarker(from description: String?) -> String? {
        guard let description else { return nil }
        let stripped = description.replacingOccurrences(
            of: #"(?:\n\n)?"# + adoptionMarkerPattern,
            with: "",
            options: .regularExpression
        )
        return stripped.isEmpty ? nil : stripped
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

    // MARK: - Local deletion propagation (issues #11/#12)

    /// Tombstones older than this are abandoned (purged without a DELETE) —
    /// the remote state has long since been pulled and re-deleting risks
    /// removing a card the user re-created.
    private static let tombstoneMaxAge: TimeInterval = 30 * 24 * 3600

    private func isStale(_ deletedAt: Date?) -> Bool {
        let age = Date().timeIntervalSince(deletedAt ?? .distantPast)
        return age > Self.tombstoneMaxAge
    }

    private func fetchCardTombstones() -> [CardTombstone] {
        let request: NSFetchRequest<CardTombstone> = CardTombstone.fetchRequest()
        return (try? context.fetch(request)) ?? []
    }

    private func fetchColumnTombstones() -> [ColumnTombstone] {
        let request: NSFetchRequest<ColumnTombstone> = ColumnTombstone.fetchRequest()
        return (try? context.fetch(request)) ?? []
    }

    /// Issues `DELETE /cards/:number` for every live card tombstone. Purges
    /// the tombstone on success or when the card is already gone (404/410);
    /// keeps it for retry (recording the error) on anything else.
    private func pushCardDeletions(into result: inout FizzySyncResult) async {
        for tombstone in fetchCardTombstones() {
            if isStale(tombstone.deletedAt) {
                context.delete(tombstone)
                continue
            }
            do {
                try await client.deleteCard(number: Int(tombstone.fizzyNumber))
                context.delete(tombstone)
                result.itemsDeleted += 1
            } catch FizzyError.notFound, FizzyError.unexpectedStatus(410) {
                // Already deleted remotely — outcome achieved.
                context.delete(tombstone)
            } catch {
                result.errors.append("Delete card #\(tombstone.fizzyNumber): \(error)")
            }
        }
    }

    /// Issues `DELETE /boards/:id/columns/:column_id` for every live column
    /// tombstone belonging to the paired board. Same purge/retry semantics
    /// as `pushCardDeletions`.
    private func pushColumnDeletions(localBoard: Board, fizzyBoardID: String, into result: inout FizzySyncResult) async {
        let localBoardID = localBoard.id?.uuidString
        for tombstone in fetchColumnTombstones() {
            if isStale(tombstone.deletedAt) {
                context.delete(tombstone)
                continue
            }
            guard tombstone.boardID == localBoardID, let columnID = tombstone.fizzyColumnID else { continue }
            do {
                try await client.deleteColumn(boardID: fizzyBoardID, columnID: columnID)
                context.delete(tombstone)
                result.itemsDeleted += 1
            } catch FizzyError.notFound, FizzyError.unexpectedStatus(410) {
                context.delete(tombstone)
            } catch {
                result.errors.append("Delete column \(columnID): \(error)")
            }
        }
    }

    // MARK: - Column reconciliation (issue #12)

    /// Pairs local columns with remote ones and pushes local changes:
    ///
    /// 1. Remote columns are matched to local ones by `fizzyColumnID`.
    ///    Paired columns whose names differ get the *local* name PUT to the
    ///    server (local rename wins — `sync()` has no per-column timestamp
    ///    to arbitrate with).
    /// 2. Unmatched remote columns claim an unpaired local column with the
    ///    same normalized name (ID backfill for pre-existing pairs), or are
    ///    created locally — unless tombstoned (delete wins).
    /// 3. Local columns still unpaired afterwards are new → POST to fizzy
    ///    and the returned ID is claimed.
    ///
    /// Returns the normalized-name → Column map used for card placement.
    /// Column reordering/position is out of scope.
    private func reconcileColumns(
        localBoard: Board,
        fizzyBoardID: String,
        remoteColumns: [FizzyColumn],
        blockedColumnIDs: Set<String>,
        into result: inout FizzySyncResult
    ) async -> [String: Column] {
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let pairedByColumnID: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col in col.fizzyColumnID.map { ($0, col) } }
        )

        for remote in remoteColumns where !blockedColumnIDs.contains(remote.id) {
            if let paired = pairedByColumnID[remote.id] {
                // Rename push: local name differs from remote → PUT local name.
                if let localName = paired.name, localName != remote.name {
                    do {
                        _ = try await client.updateColumn(
                            boardID: fizzyBoardID,
                            columnID: remote.id,
                            with: FizzyColumnWrite(name: localName)
                        )
                        result.itemsUpdated += 1
                    } catch {
                        result.errors.append("Rename column '\(localName)': \(error)")
                    }
                }
            } else if let match = localColumns.first(where: {
                $0.fizzyColumnID == nil
                    && FizzySyncMapping.normalizedColumnName($0.name ?? "") == FizzySyncMapping.normalizedColumnName(remote.name)
            }) {
                // Backfill: column pair predates fizzyColumnID — claim the ID.
                match.fizzyColumnID = remote.id
            } else {
                // Remote-only column → create locally, already paired.
                let new = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                new.fizzyColumnID = remote.id
            }
        }

        // Local columns still unpaired are local creates → push.
        for column in localColumns where column.fizzyColumnID == nil {
            do {
                let created = try await client.createColumn(
                    boardID: fizzyBoardID,
                    FizzyColumnWrite(name: column.name ?? "Untitled Column")
                )
                column.fizzyColumnID = created.id
                result.itemsCreated += 1
            } catch {
                result.errors.append("Push column '\(column.name ?? "(untitled)")': \(error)")
            }
        }

        // Placement map for the card pull (includes any columns created above).
        let allColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        return Dictionary(
            allColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
    /// Maps every remote tag to a local `Label` (find-or-create by
    /// case-insensitive name).
    ///
    /// `modifiedAt` is reset to `fizzyUpdatedAt` so the next steady-state LWW
    /// check sees "local untouched since last sync" and doesn't spuriously
    /// re-push. Steady-state convergence depends on this.
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        // Local copies never contain adoption markers (issue #14).
        card.cardDescription = Self.strippingAdoptionMarker(from: remote.description)
        card.isGolden = remote.golden
        card.fizzyID = remote.id
        card.fizzyNumber = Int64(remote.number)
        card.fizzyUpdatedAt = remote.lastActiveAt
        card.modifiedAt = remote.lastActiveAt

        // All remote tags map to local Labels (issue #19 lifts the Phase 4a
        // first-tag-only limitation). Remote is authoritative on pull (LWW).
        let remoteLabels = remote.tags.map { findOrCreateLabel(name: $0) }
        card.labels = NSSet(array: remoteLabels)

        // Assignees ride the column-cards list payload (not the single-card
        // doc). Remote-authoritative on pull, like tags. A nil array means
        // the payload doesn't carry the field — leave the local blob alone.
        if let remoteAssignees = remote.assignees {
            let mapped = remoteAssignees.map { CardAssignee(id: $0.id, name: $0.name) }
            if card.assignees != mapped {
                card.assignees = mapped
            }
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
    ///
    /// Adoption markers persist on remote cards BY DESIGN (issue #21,
    /// temporarily reversing #15's remote stripping): the fizzy pairing
    /// fields (`fizzyID`/`fizzyNumber`/`fizzyUpdatedAt`) are CloudKit-synced,
    /// and a CloudKit import can clobber a fresh pairing back to nil — after
    /// which the push step would POST a duplicate of every clobbered card.
    /// A persistent `<!--fk:UUID-->` marker lets marker adoption (#14)
    /// deterministically re-pair the card to its remote twin instead. The
    /// PUT payload therefore re-embeds the marker (mirroring `postCard`);
    /// previously a local edit silently wiped it because the payload carried
    /// the marker-free local description. Remote stripping returns once
    /// pairing moves to a local-only (non-CloudKit) store.
    private func putCard(_ card: Card, number: Int64) async throws -> FizzyCard {
        let outgoingDescription: String?
        if let localID = card.id {
            let marker = Self.adoptionMarker(for: localID)
            outgoingDescription = card.cardDescription.map { "\($0)\n\n\(marker)" } ?? marker
        } else {
            outgoingDescription = card.cardDescription
        }
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: outgoingDescription,
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
        // Append the hidden adoption marker (issue #14) so the card can be
        // re-claimed deterministically if the pairing is lost (crash after
        // POST, save failure, CloudKit clobber). The marker persists on the
        // remote by design — see putCard (issue #21).
        let outgoingDescription: String?
        if let localID = card.id {
            let marker = Self.adoptionMarker(for: localID)
            outgoingDescription = card.cardDescription.map { "\($0)\n\n\(marker)" } ?? marker
        } else {
            outgoingDescription = card.cardDescription
        }
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: outgoingDescription,
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
