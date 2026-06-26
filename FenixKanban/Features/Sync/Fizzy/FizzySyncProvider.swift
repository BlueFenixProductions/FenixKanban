import Foundation
import CoreData
import WidgetKit

/// Bridges `FizzySyncEngine` to the app's generic `BoardSyncProvider` plugin
/// protocol. Constructed once at app launch in `FenixKanbanApp.init()` and
/// registered in `PluginRegistry.shared`. Holds `FizzyAuthState` and
/// `FizzyBoardPairingStore` for the lifetime of the app process; rebuilds
/// `FizzyClient` + `FizzySyncEngine` on demand so changes to `authState`
/// (token paste, slug refresh) are picked up without re-registration.
///
/// Phase 5 only handles the manual entry points (`fetchRemoteBoards`,
/// `sync`). The foreground polling timer lands in Phase 6.
@MainActor
final class FizzySyncProvider: BoardSyncProvider, SyncTriggering {

    let providerName: String = "Fizzy"
    let iconName: String = "bolt.circle.fill"

    private let authState: FizzyAuthState
    private let persistence: PersistenceController
    private let urlSession: URLSession
    private let clock: any Clock<Duration> & Sendable
    /// Device-local board pairing authority (issue #18). Injectable so tests
    /// never touch the real Application Support sidecar.
    private let boardPairingStore: FizzyBoardPairingStore
    /// Device-local pairing authority handed to every engine the provider
    /// builds (issue #21 A′). Injectable so tests never touch the real
    /// Application Support sidecar.
    private let pairingStore: FizzyCardPairingStore
    /// Device-local conflict store. Injectable so tests never touch the real
    /// Application Support sidecar.
    private let conflictStore: FizzyConflictStore

    init(
        authState: FizzyAuthState,
        persistence: PersistenceController,
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> & Sendable = ContinuousClock(),
        boardPairingStore: FizzyBoardPairingStore = .shared,
        pairingStore: FizzyCardPairingStore = .shared,
        conflictStore: FizzyConflictStore = .shared
    ) {
        self.authState = authState
        self.persistence = persistence
        self.urlSession = urlSession
        self.clock = clock
        self.boardPairingStore = boardPairingStore
        self.pairingStore = pairingStore
        self.conflictStore = conflictStore
    }

    /// `true` when both token and slug are present in the Keychain.
    /// The UI uses this to choose between the verify view and the
    /// paired/unpaired views.
    var isAuthenticated: Bool {
        authState.isConfigured
    }

    /// Throws `FizzyError.requiresInteractiveAuth` — the BoardSyncProvider
    /// generic auth flow doesn't fit Fizzy's "paste a token + verify"
    /// shape. The UI uses this signal to push `FizzyAuthView` instead.
    func authenticate() async throws {
        throw FizzyError.requiresInteractiveAuth
    }

    /// Clears Keychain entries and the singleton pairing. **Does NOT
    /// touch local `Card` data** — re-pairing to the same Fizzy board
    /// later will re-bind cards via the engine's orphan-claim logic.
    func signOut() async throws {
        authState.clear()
        boardPairingStore.clearAll()
    }

    /// Clears the board pairing while keeping the Keychain token (issue
    /// #18 re-pair flow). Re-pairing must never cost the token — minting a
    /// new one requires the email flow, which may be unavailable. The UI
    /// routes back to `FizzyAuthPairView` after calling this.
    func changePairing() {
        boardPairingStore.clearAll()
    }

    /// `GET /:account/boards` — maps the Fizzy DTOs to the generic
    /// `RemoteBoard` shape the picker UI consumes.
    func fetchRemoteBoards() async throws -> [RemoteBoard] {
        guard let client = makeClient() else {
            throw FizzyError.requiresInteractiveAuth
        }
        let boards = try await client.get("/boards", as: [FizzyBoard].self)
        return boards.map { b in
            RemoteBoard(
                id: b.id,
                name: b.name,
                description: nil,
                url: b.url,
                provider: providerName
            )
        }
    }

    /// Runs the steady-state sync cycle via `FizzySyncEngine.sync(localBoardID:)` and
    /// translates the engine's `FizzySyncResult` into the generic
    /// `SyncResult` returned by `BoardSyncProvider`. The `remoteProjectId`
    /// parameter is required by the protocol but unused here — the
    /// `boardPairingStore` keyed on `boardId` is the authoritative source.
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult {
        guard let engine = makeEngine(for: boardId) else {
            throw FizzyError.requiresInteractiveAuth
        }
        boardActivity.markSyncing(boardId)
        do {
            let result = try await engine.sync(localBoardID: boardId)
            if let e = result.errors.first {
                boardActivity.markError(boardId, e)
            } else {
                boardActivity.markIdle(boardId)
            }
            WidgetCenter.shared.reloadAllTimelines()
            return SyncResult(
                itemsCreated: result.itemsCreated,
                itemsUpdated: result.itemsUpdated,
                itemsDeleted: result.itemsDeleted,
                errors: result.errors,
                syncDate: .now
            )
        } catch {
            boardActivity.markError(boardId, error.localizedDescription)
            throw error
        }
    }

    /// Returns `lastSyncAt` from the board pairing store for `boardId`.
    func lastSyncDate(for boardId: UUID) -> Date? {
        boardPairingStore.pairing(forLocal: boardId)?.lastSyncAt
    }

    // MARK: - SyncTriggering (Phase 6 foreground scheduler)

    /// `true` when both token and at least one board pairing exist.
    var isPaired: Bool {
        authState.isConfigured && !boardPairingStore.isEmpty
    }

    /// Returns the ordered list of local board IDs to sync this round.
    /// `currentBoardID` (frontmost board) is promoted to the front when it is
    /// in the `syncEnabled` set; the rest follow in stored insertion order.
    /// Boards with `syncEnabled == false` are excluded entirely.
    private func orderedBoardsToSync() -> [UUID] {
        let enabled = boardPairingStore.all().filter(\.syncEnabled).map(\.localBoardID)
        guard let front = currentBoardID, enabled.contains(front) else { return enabled }
        return [front] + enabled.filter { $0 != front }
    }

    /// Serial round-robin sync of every `syncEnabled` pairing. The frontmost
    /// board (`currentBoardID`) syncs first, then the rest in stored order.
    /// One engine at a time — preserves the engine's reentrancy guard.
    ///
    /// Errors (thrown or non-empty result.errors) mark `activityState` as
    /// `.error` rather than `.idle`; `lastSyncAt` advances on partial failures
    /// because the cycle ran. Also re-posts pending comments and steps.
    func triggerSync(activityState: SyncActivityState) async {
        let order = orderedBoardsToSync()
        guard !order.isEmpty else { return }
        var aggregate = FizzySyncResult()
        var firstError: String?
        for boardID in order {
            guard let engine = makeEngine(for: boardID) else { continue }
            boardActivity.markSyncing(boardID)
            do {
                let result = try await engine.sync(localBoardID: boardID)
                aggregate.merge(result)
                if let e = result.errors.first {
                    boardActivity.markError(boardID, e)
                    if firstError == nil { firstError = e }
                } else {
                    boardActivity.markIdle(boardID)
                }
            } catch {
                boardActivity.markError(boardID, error.localizedDescription)
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        activityState.update(from: aggregate, conflictStore: conflictStore)
        if let firstError { activityState.markError(firstError) }
        activityState.lastSyncAt = .now
        await retryPendingComments()
        await retryPendingSteps()
    }

    /// Fires one background sync cycle over all `syncEnabled` pairings.
    /// Silently absorbs errors so the scheduler's loop doesn't crash on
    /// transient failures; errors are surfaced through `activityState` on the
    /// scheduler. Also re-posts any pending comments and steps.
    func triggerSync() async {
        for boardID in orderedBoardsToSync() {
            guard let engine = makeEngine(for: boardID) else { continue }
            _ = try? await engine.sync(localBoardID: boardID)
        }
        await retryPendingComments()
        await retryPendingSteps()
    }

    /// Re-posts all `pendingWrite == true` CachedComment entries found in
    /// the viewContext. No-op when unauthenticated. Called from `triggerSync()`
    /// on every scheduler tick.
    func retryPendingComments() async {
        guard let client = makeClient() else { return }
        let context = persistence.viewContext
        let request: NSFetchRequest<CachedComment> = CachedComment.fetchRequest()
        request.predicate = NSPredicate(format: "pendingWrite == YES")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CachedComment.createdAt, ascending: true)]
        let pending = (try? context.fetch(request)) ?? []
        for comment in pending {
            guard !comment.isDeleted, comment.managedObjectContext != nil else { continue }
            let cardNumber = Int(comment.cardFizzyNumber)
            let body = comment.body ?? ""
            guard !body.isEmpty else { continue }
            do {
                let created = try await client.createComment(cardNumber: cardNumber, body: body)
                comment.fizzyCommentID = created.id
                comment.pendingWrite = false
                if context.hasChanges { try? context.save() }
            } catch {
                // Leave pending; will be retried on the next tick.
            }
        }
    }

    /// Re-pushes pending step writes (task #29 — symmetric with
    /// `retryPendingComments`; both run on every scheduler tick). A step
    /// with no `fizzyStepID` is a failed create → POST; one with an ID is a
    /// failed update → PUT. Failures stay pending for the next tick.
    func retryPendingSteps() async {
        guard let client = makeClient() else { return }
        let context = persistence.viewContext
        let request: NSFetchRequest<CardStep> = CardStep.fetchRequest()
        request.predicate = NSPredicate(format: "pendingWrite == YES")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CardStep.sortOrder, ascending: true)]
        let pending = (try? context.fetch(request)) ?? []
        for step in pending {
            guard !step.isDeleted, step.managedObjectContext != nil,
                  let card = step.card, card.fizzyNumber > 0 else { continue }
            let cardNumber = Int(card.fizzyNumber)
            do {
                if let stepID = step.fizzyStepID {
                    _ = try await client.updateStep(
                        cardNumber: cardNumber, id: stepID,
                        content: step.content, completed: step.completed
                    )
                } else {
                    let created = try await client.createStep(
                        cardNumber: cardNumber,
                        content: step.content ?? "",
                        completed: step.completed
                    )
                    step.fizzyStepID = created.id
                }
                step.pendingWrite = false
            } catch {
                continue // stays pending; next tick retries
            }
        }
        if context.hasChanges { try? context.save() }
    }

    // MARK: - Conflict resolution (task #70)

    /// All currently open conflicts, for the UI to display.
    func conflicts() -> [ConflictRecord] {
        conflictStore.all
    }

    /// Keep-mine resolution: PUT local title/desc, advance watermark, clear record.
    func resolveKeepMine(cardID: UUID) async throws {
        guard let engine = makeEngine() else { return }
        try await engine.resolveKeepMine(cardID: cardID)
    }

    /// Take-theirs resolution: re-fetch remote, apply, clear record.
    func resolveTakeTheirs(cardID: UUID) async throws {
        guard let engine = makeEngine() else { return }
        try await engine.resolveTakeTheirs(cardID: cardID)
    }

    // MARK: - Internal accessors (used by FizzyAuthView sub-views)

    /// Exposed so `FizzyAuthView` and its sub-views can drive verify / pair
    /// flows without each constructing their own auth handles.
    var authStateRef: FizzyAuthState { authState }
    var persistenceRef: PersistenceController { persistence }

    /// Builds a `FizzyClient` using a caller-supplied token + slug.
    /// Used by the verify view when the slug isn't known yet (the verify
    /// view passes an empty slug; `/my/identity` paths skip slug
    /// interpolation).
    func makeClient(accessToken: String, accountSlug: String) -> FizzyClient {
        FizzyClient(
            baseURL: authState.baseURL,
            accessToken: accessToken,
            accountSlug: accountSlug,
            urlSession: urlSession,
            clock: clock
        )
    }

    /// Builds a `FizzyClient` using the currently-stored credentials.
    /// Returns `nil` when `authState.isConfigured == false`.
    func makeClient() -> FizzyClient? {
        guard let token = authState.accessToken, let slug = authState.accountSlug else {
            return nil
        }
        return makeClient(accessToken: token, accountSlug: slug)
    }

    /// Builds a `FizzySyncEngine` wired to the current auth + board pairing
    /// store + persistence. Returns `nil` when unauthenticated.
    func makeEngine() -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            boardPairingStore: boardPairingStore,
            context: persistence.viewContext,
            pairingStore: pairingStore,
            conflictStore: conflictStore
        )
    }

    // MARK: - Per-board routing (Task 4 / issue #18)

    /// The board currently visible in the UI. The scheduler syncs this board
    /// first each round (Task 5). Set by `BoardView` on appear.
    var currentBoardID: UUID?

    /// Per-board transient activity for the board browser (issue #18, Phase 7b).
    private let boardActivity = FizzyBoardSyncActivity()

    /// Exposes the per-board activity registry to the board-browser UI.
    var boardActivityRef: FizzyBoardSyncActivity { boardActivity }

    /// Builds a `FizzySyncEngine` for a specific local board. Shares the same
    /// underlying stores as `makeEngine()` — the board ID is passed through to
    /// `engine.sync(localBoardID:)` by the caller. Returns `nil` when
    /// unauthenticated.
    func makeEngine(for localBoardID: UUID) -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            boardPairingStore: boardPairingStore,
            context: persistence.viewContext,
            pairingStore: pairingStore,
            conflictStore: conflictStore
        )
    }

    // MARK: - Board pairing CRUD

    /// Records a pairing between a local board and its Fizzy twin.
    /// Idempotent — a second call with the same `localBoardID` updates the row.
    func pair(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?) {
        boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: localBoardID,
            fizzyBoardID: fizzyBoardID,
            fizzyBoardName: fizzyBoardName
        ))
    }

    /// Removes the pairing for `localBoardID`. **Never touches Card data** —
    /// re-pairing the same board later re-binds via orphan-claim logic.
    func unpair(localBoardID: UUID) {
        boardPairingStore.remove(localBoardID: localBoardID)
    }

    /// Enables or disables scheduled sync for a specific board.
    func setSyncEnabled(localBoardID: UUID, _ enabled: Bool) {
        boardPairingStore.setSyncEnabled(localBoardID: localBoardID, enabled)
    }

    /// Exposes the board pairing store for the board-browser UI (Task 5+).
    var boardPairingStoreRef: FizzyBoardPairingStore { boardPairingStore }
}
