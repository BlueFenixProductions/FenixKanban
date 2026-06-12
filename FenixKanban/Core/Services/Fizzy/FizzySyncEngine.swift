import Foundation
import CoreData

/// Orchestrates first-sync and steady-state sync between a paired local
/// FenixKanban board and the corresponding Fizzy board.
///
/// Composition is deliberate: the engine owns no Keychain or UserDefaults
/// access of its own — it consumes the `FizzyAuthState`, `FizzyBoardMapping`,
/// and `FizzyCardPairingStore` instances injected at construction. Likewise,
/// all HTTP goes through `FizzyClient`. This keeps the engine fully testable
/// with `MockURLProtocol` and synthetic auth/mapping fixtures.
///
/// `FizzyCardPairingStore` is the single authority on card pairing (issue #21
/// A′). CloudKit-synced attributes `fizzyID`/`fizzyNumber` are demoted to a
/// self-healing hint channel: written at pairing time and re-healed every sync
/// for the UI's per-card routes and multi-device bootstrap, but never read for
/// sync decisions (except to seed a cold store on upgrade/reinstall).
@MainActor
final class FizzySyncEngine {

    private let client: FizzyClient
    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let context: NSManagedObjectContext
    /// Device-local pairing authority (issue #21 A′). CloudKit-synced
    /// attributes on Card are demoted to a self-healing hint channel.
    private let pairingStore: FizzyCardPairingStore

    /// Reentrancy guard. `sync()`/`syncFirst(mode:)` suspend at every HTTP
    /// await, so a second call (double-tapped Sync Now, a pair-then-sync
    /// overlap, or Phase 6's polling timer) could interleave with the first,
    /// snapshot the same nil-`fizzyID` cards, and POST them twice — the
    /// UAT "~40 duplicate cards" bug. While a run is in flight, subsequent
    /// calls return an empty `FizzySyncResult` immediately.
    private var isSyncing = false

    /// Per-column card-list cache for ETag-conditional pulls (task #61).
    /// Keyed by request path; in-memory by design (cold start re-fetches
    /// once, then steady-state polling 304s). Holding the cards alongside
    /// the etag keeps the remote universe complete on a 304, which is what
    /// lets the soft-delete and LWW logic run unchanged.
    private struct CardListCacheEntry {
        var etag: String
        var singlePage: Bool
        var cards: [FizzyCard]
    }
    private var cardListCache: [String: CardListCacheEntry] = [:]

    init(
        client: FizzyClient,
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        context: NSManagedObjectContext,
        pairingStore: FizzyCardPairingStore
    ) {
        self.client = client
        self.authState = authState
        self.mapping = mapping
        self.context = context
        self.pairingStore = pairingStore
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
    /// the device-local pairing store and won't pair anything by title.
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

        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID, remoteColumns: remoteColumns)

        // Local cards keyed by fizzyID — pairing comes from the device-local
        // store (issue #21 A′), which CloudKit cannot clobber. Seed any
        // missing store entries from legacy hint attributes (per-card, so a
        // partially-warm store still adopts remaining hints).
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []

        // ID-keyed placement map (reconcileColumns has just paired/created
        // local columns, so fizzyColumnID is authoritative here).
        let localColumnsByFizzyID: [String: Column] = Dictionary(
            localColumns.compactMap { col in col.fizzyColumnID.map { ($0, col) } },
            uniquingKeysWith: { first, _ in first }
        )
        let localCards: [Card] = localColumns.flatMap { col -> [Card] in
            (col.cards as? Set<Card>).map { Array($0) } ?? []
        }
        seedPairingStoreFromHints(localCards: localCards, remoteCards: remoteCards)

        // First-wins on the pathological duplicate-pairing case (two local
        // cards claiming one remote — e.g. a CloudKit duplicate import):
        // the loser stays inert locally rather than crashing or duplicating.
        var pairedByFizzyID: [String: Card] = [:]
        for card in localCards {
            guard let p = pairing(for: card), pairedByFizzyID[p.fizzyID] == nil else { continue }
            pairedByFizzyID[p.fizzyID] = card
        }

        // Crash-after-POST recovery: precompute orphan claims so the pull loop
        // doesn't also create a duplicate from the same remote. For each local
        // card with no store pairing, try to find an unpaired remote with
        // matching title + createdAt within ±60s. First-match wins; each
        // remote is claimed by at most one local.
        let orphanWindow: TimeInterval = 60
        var orphansByLocalID: [NSManagedObjectID: String] = [:]
        var claimedRemoteIDs: Set<String> = []
        for card in localCards where pairing(for: card) == nil {
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
            let targetColumn = placementColumn(
                for: remote, in: localBoard,
                byFizzyID: localColumnsByFizzyID, byName: resolvedColumns
            )
            let card = CardRepository(context: context, pairingStore: pairingStore).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // LWW for paired cards.
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        for (fizzyID, card) in pairedByFizzyID {
            guard let remote = remoteByID[fizzyID], var p = pairing(for: card) else { continue }
            // Backfill the card number — Fizzy addresses per-card routes by
            // `number`, not the opaque `id`. Cards paired before this field
            // existed self-heal here on their next sync.
            if p.fizzyNumber == 0 {
                p.fizzyNumber = Int64(remote.number)
                if let id = card.id { pairingStore.setPairing(p, for: id) }
            }
            // Heal the hint attributes every cycle — CloudKit imports may
            // have clobbered them; the UI reads them for per-card routes.
            healHints(on: card, fizzyID: p.fizzyID, number: p.fizzyNumber)

            let localFizzyTimestamp = p.fizzyUpdatedAt
            let localModified = card.modifiedAt ?? .distantPast
            let remoteTimestamp = remote.lastActiveAt

            if remoteTimestamp > localFizzyTimestamp && localModified <= localFizzyTimestamp {
                // Remote newer, local untouched → pull. Includes column
                // placement: the per-column fetch stamps each card's source
                // column, so a remote move lands here. Direct relationship
                // assignment doesn't bump modifiedAt → no echo-push.
                applyRemote(remote, to: card)
                if let remoteColumnID = remote.column?.id,
                   card.column?.fizzyColumnID != remoteColumnID,
                   let target = localColumnsByFizzyID[remoteColumnID] {
                    card.column = target
                }
                result.itemsUpdated += 1
            } else if localModified > localFizzyTimestamp {
                // Local edited since last sync → push.
                do {
                    let updated = try await putCard(card, number: p.fizzyNumber)
                    recordPairing(for: card, fizzyID: fizzyID, number: p.fizzyNumber, updatedAt: updated.lastActiveAt)
                    card.modifiedAt = updated.lastActiveAt
                    result.itemsUpdated += 1
                } catch let error as FizzyError {
                    result.errors.append("Push update '\(card.title ?? "(untitled)")': \(error)")
                }
            }
            // else: both equal or remote stale → no-op.
        }

        // Soft-delete / lifecycle: paired local cards missing from the
        // per-column lists. Those lists exclude closed/not-now cards, so
        // absence is NOT proof of deletion — confirm via the single-card
        // endpoint. 404 deletes locally; an alive card transitions to the
        // wire lifecycle state (#13): closed → .closed, postponed → .notNow.
        // Content from the detail doc applies only under the usual LWW gate
        // (local untouched) — a local edit made while the card was closed
        // must not be clobbered. A card we can't verify (no number, network
        // error) is kept for a later cycle.
        for (fizzyID, card) in pairedByFizzyID where remoteByID[fizzyID] == nil {
            guard let p = pairing(for: card), p.fizzyNumber > 0 else { continue }
            do {
                let detail = try await client.card(number: Int(p.fizzyNumber))
                let localModified = card.modifiedAt ?? .distantPast
                if detail.lastActiveAt > p.fizzyUpdatedAt && localModified <= p.fizzyUpdatedAt {
                    applyRemote(detail, to: card) // full pull incl. lifecycle
                    result.itemsUpdated += 1
                } else if card.lifecycleStatus != detail.wireLifecycleStatus {
                    // Local content is newer — transition lifecycle only.
                    card.lifecycleStatus = detail.wireLifecycleStatus
                    result.itemsUpdated += 1
                }
            } catch FizzyError.notFound {
                if let id = card.id { pairingStore.removePairing(for: id) }
                context.delete(card)
                result.itemsDeleted += 1
            } catch {
                result.errors.append("Verify '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        // Push: local cards with no pairing → claim a precomputed orphan or
        // POST a new card. The pairing lands in the store the moment the
        // server responds — BEFORE context.save() — so a later save failure
        // or crash cannot lose it and duplicate the card next sync.
        //
        // `!card.isDeleted` guards against resurrection: the soft-delete loop
        // above unpairs + deletes server-gone cards, but `localCards` is a
        // pre-delete snapshot — without the guard the just-deleted card
        // would be POSTed straight back to the server (latent duplicate
        // source, caught by the #48 placement suite).
        for card in localCards where pairing(for: card) == nil && !card.isDeleted {
            if let orphanID = orphansByLocalID[card.objectID],
               let orphan = remoteByID[orphanID] {
                recordPairing(for: card, fizzyID: orphan.id, number: Int64(orphan.number), updatedAt: orphan.lastActiveAt)
                card.modifiedAt = orphan.lastActiveAt
                result.itemsUpdated += 1
                continue
            }
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
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
        // not pass silently (issue #15). Pairing state persists in the
        // device-local store independently of this save, so a save failure
        // can no longer cause duplicate POSTs on the next sync (issue #21 A′).
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
                guard let fizzyID = pairing(for: card)?.fizzyID else { continue }
                let shouldPin = pinnedIDs.contains(fizzyID)
                if card.isPinned != shouldPin {
                    card.isPinned = shouldPin
                }
            }
        }
    }

    // MARK: - Pairing store access (issue #21 A′)

    /// The store entry for a card, if paired.
    private func pairing(for card: Card) -> FizzyCardPairing? {
        card.id.flatMap { pairingStore.pairing(for: $0) }
    }

    /// Records (or refreshes) a card's pairing in the local store and heals
    /// the CloudKit-synced hint attributes. The store is the authority; the
    /// attributes survive only as a bootstrap hint channel (cold store on a
    /// fresh install / second device) and for the UI's per-card routes.
    private func recordPairing(for card: Card, fizzyID: String, number: Int64, updatedAt: Date) {
        guard let id = card.id else { return }
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: fizzyID, fizzyNumber: number, fizzyUpdatedAt: updatedAt),
            for: id
        )
        healHints(on: card, fizzyID: fizzyID, number: number)
    }

    /// Re-writes the hint attributes when they drift from the store —
    /// CloudKit imports clobber them with stale record versions; nothing
    /// reads them for sync decisions. Never bumps `modifiedAt`: hint writes
    /// are not content edits and must not trigger LWW echo-pushes.
    private func healHints(on card: Card, fizzyID: String, number: Int64) {
        if card.fizzyID != fizzyID { card.fizzyID = fizzyID }
        if card.fizzyNumber != number { card.fizzyNumber = number }
    }

    /// Seeds store entries from the CloudKit-carried hint attributes for any
    /// card that doesn't have one yet: upgrade from a pre-A′ build, fresh
    /// reinstall, a second device whose CloudKit import lands late, or a
    /// partially-completed earlier seeding run. Per-card (not gated on an
    /// empty store) so a partially-warm store still adopts remaining hints
    /// instead of letting the push loop duplicate them. A hint with a number
    /// but no fizzyID (pre-A′ clobber residue) resolves through the remote
    /// list. Worst case for a stale hint pointing at an already-claimed
    /// remote: a second store entry for the same fizzyID — the
    /// `pairedByFizzyID` first-wins build keeps the duplicate inert (never
    /// pushed, never deleted).
    private func seedPairingStoreFromHints(localCards: [Card], remoteCards: [FizzyCard]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        let remoteByNumber: [Int64: FizzyCard] = Dictionary(
            remoteCards.map { (Int64($0.number), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for card in localCards {
            guard let id = card.id else { continue }
            guard pairing(for: card) == nil else { continue }
            if let fizzyID = card.fizzyID {
                let number = card.fizzyNumber != 0
                    ? card.fizzyNumber
                    : remoteByID[fizzyID].map { Int64($0.number) } ?? 0
                pairingStore.setPairing(
                    FizzyCardPairing(
                        fizzyID: fizzyID, fizzyNumber: number,
                        fizzyUpdatedAt: card.fizzyUpdatedAt ?? .distantPast
                    ),
                    for: id
                )
            } else if card.fizzyNumber != 0, let remote = remoteByNumber[card.fizzyNumber] {
                pairingStore.setPairing(
                    FizzyCardPairing(
                        fizzyID: remote.id, fizzyNumber: card.fizzyNumber,
                        fizzyUpdatedAt: card.fizzyUpdatedAt ?? .distantPast
                    ),
                    for: id
                )
            }
        }
    }

    // MARK: - Mode implementations

    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        // Push mode: POST every local card on the paired board that isn't
        // already paired in the store. Adopt legacy attribute hints before
        // deciding what to POST (no remote list in push mode — number-only
        // hints can't resolve here).
        var result = FizzySyncResult()
        let columns = (localBoard.columns as? Set<Column>) ?? Set<Column>()
        let cards: [Card] = columns.flatMap { column in
            (column.cards as? Set<Card>) ?? Set<Card>()
        }
        seedPairingStoreFromHints(localCards: cards, remoteCards: [])

        for card in cards where pairing(for: card) == nil {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
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

        // 1. Wipe local cards on the paired board (and clear their pairings
        //    from the store so stale entries don't ghost later syncs).
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { column -> [Card] in
            (column.cards as? Set<Card>).map { Array($0) } ?? []
        }
        for card in localCards {
            if let id = card.id { pairingStore.removePairing(for: id) }
            context.delete(card)
            result.itemsDeleted += 1
        }

        // 2. Pull remote columns; pair or create local columns, claiming the
        //    fizzy column ID for keyed placement below (task #48).
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        var columnsByFizzyID: [String: Column] = [:]
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            let column: Column
            if let existing = resolvedColumns[key] {
                column = existing
            } else {
                column = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = column
            }
            column.fizzyColumnID = remote.id
            columnsByFizzyID[remote.id] = column
        }

        // 3. Pull cards column-by-column and mirror each in its source column.
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID, remoteColumns: remoteColumns)
        for remote in remoteCards {
            let targetColumn = placementColumn(
                for: remote, in: localBoard,
                byFizzyID: columnsByFizzyID, byName: resolvedColumns
            )
            let card = CardRepository(context: context, pairingStore: pairingStore).createCard(in: targetColumn, title: remote.title)
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

        // Fetch both sides (cards per column so placement is keyed, #48).
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID, remoteColumns: remoteColumns)

        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { column -> [Card] in
            (column.cards as? Set<Card>).map { Array($0) } ?? []
        }

        // Adopt legacy attribute hints — after both sides are fetched so
        // number-only hints can resolve against the remote list.
        seedPairingStoreFromHints(localCards: localCards, remoteCards: remoteCards)

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

        // Pair or create local columns for every remote one, claiming the
        // fizzy column ID for keyed placement (task #48).
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        var columnsByFizzyID: [String: Column] = [:]
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            let column: Column
            if let existing = resolvedColumns[key] {
                column = existing
            } else {
                column = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = column
            }
            column.fizzyColumnID = remote.id
            columnsByFizzyID[remote.id] = column
        }

        // Pull remote-only cards (not in local, not a collision).
        for remote in remoteCards where !localTitles.contains(remote.title.lowercased()) {
            let targetColumn = placementColumn(
                for: remote, in: localBoard,
                byFizzyID: columnsByFizzyID, byName: resolvedColumns
            )
            let card = CardRepository(context: context, pairingStore: pairingStore).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // Push local-only cards (unpaired in the store, not a collision).
        for card in localCards where pairing(for: card) == nil
                                && !remoteTitlesLower.contains(card.title?.lowercased() ?? "") {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
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

    /// Fetches the board's open cards column-by-column via
    /// `GET /boards/:id/columns/:column_id/cards` — the only list shape that
    /// carries `column` (and `assignees`). The board-wide
    /// `/cards?board_ids[]=` list omits both, which made pull placement
    /// arbitrary (task #48). Defensive de-dupe by card id in case a card is
    /// served under two columns mid-move.
    ///
    /// NOTE: these lists exclude closed/not-now cards, so absence here is
    /// not proof of server-side deletion — the soft-delete path must confirm
    /// via `GET /cards/:number` before deleting locally.
    ///
    /// ETag-conditional (task #61): each column's list is fetched with
    /// `If-None-Match` when the previous response was single-page; a 304
    /// reuses the cached card list, so the returned "universe" is always
    /// complete and the LWW / soft-delete / push logic downstream runs
    /// unchanged. The cache is in-memory by design — a cold start simply
    /// re-fetches once.
    private func fetchRemoteCards(boardID: String, remoteColumns: [FizzyColumn]) async throws -> [FizzyCard] {
        var cards: [FizzyCard] = []
        for column in remoteColumns {
            let path = "/boards/\(boardID)/columns/\(column.id)/cards"
            let cached = cardListCache[path]
            // Conditional only when the prior response was single-page —
            // page-1-ETag semantics across pages are unverified (probe B3-4).
            let conditionalETag = (cached?.singlePage == true) ? cached?.etag : nil
            let result = try await client.getAllPagesWithETag(path, etag: conditionalETag, as: [FizzyCard].self)
            if let fresh = result.items {
                cards += fresh
                if let etag = result.etag {
                    cardListCache[path] = CardListCacheEntry(etag: etag, singlePage: result.singlePage, cards: fresh)
                } else {
                    cardListCache[path] = nil
                }
            } else if let cached {
                cards += cached.cards // 304 — unchanged since the last cycle
            }
        }
        var seen = Set<String>()
        return cards.filter { seen.insert($0.id).inserted }
    }

    /// Resolves the local column for a pulled remote card: fizzy column ID
    /// first (authoritative), normalized name second (legacy pairs), any
    /// existing column third, a fresh "Imported" column as a last resort.
    private func placementColumn(
        for remote: FizzyCard,
        in localBoard: Board,
        byFizzyID: [String: Column],
        byName: [String: Column]
    ) -> Column {
        if let id = remote.column?.id, let column = byFizzyID[id] { return column }
        if let name = remote.column?.name,
           let column = byName[FizzySyncMapping.normalizedColumnName(name)] { return column }
        return byName.values.first
            ?? byFizzyID.values.first
            ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)
    }

    // MARK: - Apply remote → local

    // MARK: - Wire lifecycle mapping (#13)

    /// Writes the synced fields from a `FizzyCard` onto a local `Card`.
    /// Maps every remote tag to a local `Label` (find-or-create by
    /// case-insensitive name).
    ///
    /// `modifiedAt` is reset to `fizzyUpdatedAt` so the next steady-state LWW
    /// check sees "local untouched since last sync" and doesn't spuriously
    /// re-push. Steady-state convergence depends on this.
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        card.cardDescription = remote.description
        card.isGolden = remote.golden
        recordPairing(for: card, fizzyID: remote.id, number: Int64(remote.number), updatedAt: remote.lastActiveAt)
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

        // Lifecycle (#13): wire closed/postponed map to the local status.
        // Cards in column lists carry closed:false/postponed:false (active);
        // the single-card doc is the truth for unlisted cards. The accessor
        // stamps/clears closedAt on transitions.
        if card.lifecycleStatus != remote.wireLifecycleStatus {
            card.lifecycleStatus = remote.wireLifecycleStatus
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

/// Sync-layer mapping from the wire `closed`/`postponed` fields to the local
/// lifecycle enum. Lives here (not on the DTO file) so the Foundation-only
/// DTO sources stay reusable by fizzyctl, which doesn't link CoreData.
extension FizzyCard {
    var wireLifecycleStatus: CardLifecycleStatus {
        if closed == true { return .closed }
        if postponed == true { return .notNow }
        return .active
    }
}
