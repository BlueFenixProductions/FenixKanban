import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - MultiBoardHarness

/// Shared test harness for multi-board sync routing tests.
///
/// Wired from the same in-memory-context + `MockURLProtocol` + `FizzyAuthState`
/// conventions as `FizzySyncEngineBoardIsolationTests`. Inject a private temp
/// `fileURL` for each store so tests never touch the real sidecars.
///
/// Task 5 extensions: `provider` and `syncedBoardOrder` are added here so
/// `FizzyMultiBoardSchedulerTests` can share this harness without forking it.
@MainActor
struct MultiBoardHarness {
    let mock: MockHTTPState
    let persistence: PersistenceController
    let pairingStore: FizzyBoardPairingStore
    let cardPairingStore: FizzyCardPairingStore
    let engine: FizzySyncEngine
    let authState: FizzyAuthState

    /// A `FizzySyncProvider` wired to the same stores, auth, and persistence as
    /// the engine — seeded pairings are therefore visible to `orderedBoardsToSync()`.
    let provider: FizzySyncProvider

    /// Paths of every HTTP request issued through the engine in this harness.
    var requestedPaths: [String] {
        mock.requests.compactMap { $0.url?.path }
    }

    /// The order in which boards were synced, derived by mapping each recorded
    /// request path's fizzy board ID back to the local board ID of its pairing.
    /// Each board's FIRST request marks its turn; de-duplicated preserving order.
    var syncedBoardOrder: [UUID] {
        let pairings = pairingStore.all()
        var seen = Set<UUID>()
        var order: [UUID] = []
        for path in requestedPaths {
            guard let pairing = pairings.first(where: { path.contains($0.fizzyBoardID) }) else { continue }
            let id = pairing.localBoardID
            if seen.insert(id).inserted {
                order.append(id)
            }
        }
        return order
    }

    init() throws {
        mock = MockHTTPState()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)

        // Board pairing store — private temp file, never the real sidecar.
        pairingStore = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-board-pairings-\(UUID().uuidString).json")
        )

        // Card pairing store — private temp file.
        cardPairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )

        // Auth state keyed to a unique prefix.
        let prefix = "test.fizzy.multiboard.\(UUID().uuidString)"
        authState = FizzyAuthState(keyPrefix: prefix)
        authState.setAccessToken("t")
        authState.setAccountSlug("ACCT")

        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: ImmediateClock()
        )

        engine = FizzySyncEngine(
            client: client,
            authState: authState,
            boardPairingStore: pairingStore,
            context: persistence.viewContext,
            pairingStore: cardPairingStore
        )

        // Provider — shares the same board pairing store so seeded pairings are
        // visible to orderedBoardsToSync(). Uses the same mock session so HTTP
        // requests are recorded in `mock.requests`.
        let mappingDefaults = UserDefaults(
            suiteName: "test.fizzy.multiboard.mapping.\(UUID().uuidString)"
        )!
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        provider = FizzySyncProvider(
            authState: authState,
            mapping: mapping,
            persistence: persistence,
            urlSession: session,
            clock: ImmediateClock(),
            boardPairingStore: pairingStore,
            pairingStore: cardPairingStore
        )
    }

    /// Inserts a local `Board` with one column into the in-memory context, upserts
    /// a `FizzyBoardPairing` for it, and stubs empty-but-valid fizzy column/card
    /// responses for that fizzy id. Returns the `Board` and the `FizzyBoardPairing`.
    @discardableResult
    func seedPairedBoard(name: String, fizzyBoardID: String) -> (Board, FizzyBoardPairing) {
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: name)
        _ = boardRepo.createColumn(in: board, name: "Todo")
        try? persistence.viewContext.save()

        let pairing = FizzyBoardPairing(
            localBoardID: board.id!,
            fizzyBoardID: fizzyBoardID
        )
        pairingStore.upsert(pairing)

        // Stub empty-but-valid responses for this fizzy board's column + card
        // list endpoints. The handler is composed: later seedPairedBoard calls
        // extend the dispatch table by wrapping the prior handler.
        let existingHandler = mock.handler
        mock.handler = { req in
            guard let path = req.url?.path else {
                return (Data(), .response(for: req, status: 500))
            }
            if path.contains(fizzyBoardID) {
                switch (req.httpMethod, path) {
                case ("GET", let p) where p.hasSuffix("/columns"):
                    return (Data("[]".utf8), .ok(for: req))
                case ("GET", let p) where p.hasSuffix("/cards"):
                    return (Data("[]".utf8), .ok(for: req))
                default:
                    return (Data(), .response(for: req, status: 500))
                }
            }
            // /my/pins is account-scoped, not board-scoped.
            if path.hasSuffix("/my/pins") {
                return (Data("[]".utf8), .ok(for: req))
            }
            // Fall through to an earlier handler if one exists.
            if let existing = existingHandler {
                return try existing(req)
            }
            return (Data(), .response(for: req, status: 500))
        }

        return (board, pairing)
    }

    func tearDown() {
        authState.clear()
        try? FileManager.default.removeItem(at: pairingStore.fileURL)
        try? FileManager.default.removeItem(at: cardPairingStore.fileURL)
    }
}

// MARK: - Suite

@Suite("FizzySyncEngine multi-board routing", .serialized)
@MainActor
struct FizzySyncEngineMultiBoardTests {

    @Test("sync(localBoardID:) returns empty when the board is not paired")
    func unpairedBoardIsNoOp() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let result = try await h.engine.sync(localBoardID: UUID())   // never paired
        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(h.requestedPaths.isEmpty)                            // no HTTP at all
    }

    @Test("sync(localBoardID:) routes to that board's fizzy id only")
    func routesToPairedFizzyBoard() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let (boardA, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        _ = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")

        _ = try await h.engine.sync(localBoardID: boardA.id!)

        // Every column/card pull path for this cycle must reference fz-A, never fz-B.
        #expect(h.requestedPaths.contains { $0.contains("fz-A") })
        #expect(h.requestedPaths.allSatisfy { !$0.contains("fz-B") })
    }

    @Test("successful sync records lastSyncAt on that board's row")
    func recordsLastSync() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let (boardA, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        #expect(h.pairingStore.pairing(forLocal: boardA.id!)?.lastSyncAt == nil)
        _ = try await h.engine.sync(localBoardID: boardA.id!)
        #expect(h.pairingStore.pairing(forLocal: boardA.id!)?.lastSyncAt != nil)
    }
}
