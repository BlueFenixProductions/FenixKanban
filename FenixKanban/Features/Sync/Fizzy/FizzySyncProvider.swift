import Foundation
import CoreData

/// Bridges `FizzySyncEngine` to the app's generic `BoardSyncProvider` plugin
/// protocol. Constructed once at app launch in `FenixKanbanApp.init()` and
/// registered in `PluginRegistry.shared`. Holds Phase 2's `FizzyAuthState`
/// and `FizzyBoardMapping` for the lifetime of the app process; rebuilds
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
    private let mapping: FizzyBoardMapping
    private let persistence: PersistenceController
    private let urlSession: URLSession
    private let clock: any Clock<Duration> & Sendable
    /// Device-local pairing authority handed to every engine the provider
    /// builds (issue #21 A′). Injectable so tests never touch the real
    /// Application Support sidecar.
    private let pairingStore: FizzyCardPairingStore

    init(
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        persistence: PersistenceController,
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> & Sendable = ContinuousClock(),
        pairingStore: FizzyCardPairingStore = .shared
    ) {
        self.authState = authState
        self.mapping = mapping
        self.persistence = persistence
        self.urlSession = urlSession
        self.clock = clock
        self.pairingStore = pairingStore
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
        mapping.clear()
    }

    /// Clears the board pairing while keeping the Keychain token (issue
    /// #18 re-pair flow). Re-pairing must never cost the token — minting a
    /// new one requires the email flow, which may be unavailable. The UI
    /// routes back to `FizzyAuthPairView` after calling this.
    func changePairing() {
        mapping.clear()
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

    /// Runs the steady-state sync cycle via `FizzySyncEngine.sync()` and
    /// translates the engine's `FizzySyncResult` into the generic
    /// `SyncResult` returned by `BoardSyncProvider`. The `boardId` and
    /// `remoteProjectId` parameters are required by the protocol but
    /// Phase 5's engine pairs on a singleton basis — pairing must already
    /// match these IDs (the provider doesn't currently switch pairings
    /// per-call). They're accepted but unused.
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult {
        guard let engine = makeEngine() else {
            throw FizzyError.requiresInteractiveAuth
        }
        let result = try await engine.sync()

        // Publish a fresh widget snapshot after every successful sync so
        // the PlaygroundBoardWidget always reflects the latest board state.
        // Failures are silent — a stale snapshot is better than a crash.
        let writer = BoardSnapshotWriter(context: persistence.viewContext)
        _ = try? writer.writeSnapshot()

        return SyncResult(
            itemsCreated: result.itemsCreated,
            itemsUpdated: result.itemsUpdated,
            itemsDeleted: result.itemsDeleted,
            errors: result.errors,
            syncDate: .now
        )
    }

    /// Returns `mapping.lastSyncAt` (singleton — `boardId` is ignored
    /// since Phase 5 pairs at most one local board).
    func lastSyncDate(for boardId: UUID) -> Date? {
        mapping.lastSyncAt
    }

    // MARK: - SyncTriggering (Phase 6 foreground scheduler)

    /// `true` when both token and board pairing are configured.
    var isPaired: Bool {
        authState.isConfigured && mapping.isPaired
    }

    /// Fires one sync cycle via the engine. Silently absorbs errors so the
    /// scheduler's loop doesn't crash on transient failures; errors are
    /// surfaced through `activityState` on the scheduler.
    ///
    /// Also re-posts any pending (unsent) comments — issue #16 retry seam.
    /// This hook lives here rather than in FizzySyncEngine or FizzyClient so
    /// neither orchestrator is aware of the comment cache (single-responsibility).
    func triggerSync() async {
        guard let engine = makeEngine() else { return }
        _ = try? await engine.sync()
        await retryPendingComments()
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

    // MARK: - Internal accessors (used by FizzyAuthView sub-views)

    /// Exposed so `FizzyAuthView` and its sub-views can drive verify / pair
    /// flows without each constructing their own auth/mapping handles.
    var authStateRef: FizzyAuthState { authState }
    var mappingRef: FizzyBoardMapping { mapping }
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

    /// Builds a `FizzySyncEngine` wired to the current auth + mapping +
    /// persistence. Returns `nil` when unauthenticated.
    func makeEngine() -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext,
            pairingStore: pairingStore
        )
    }
}
