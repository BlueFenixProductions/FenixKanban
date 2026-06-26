import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardBrowserViewModel", .serialized)
@MainActor
struct FizzyBoardBrowserViewModelTests {

    // Internal (not private) so Task 4's action test suite can reuse this Harness.
    struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let authState: FizzyAuthState
        let boardPairingStore: FizzyBoardPairingStore
        let pairingStore: FizzyCardPairingStore
        let provider: FizzySyncProvider

        @MainActor
        init() {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            let prefix = "test.fizzy.browser.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            boardPairingStore = FizzyBoardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-board-pairings-\(UUID().uuidString).json"))
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json"))
            provider = FizzySyncProvider(
                authState: authState,
                persistence: persistence,
                urlSession: mock.makeSession(),
                clock: ImmediateClock(),
                boardPairingStore: boardPairingStore,
                pairingStore: pairingStore)
            authState.setAccessToken("tok"); authState.setAccountSlug("ACCT")
        }

        func tearDown() {
            authState.clear()
            try? FileManager.default.removeItem(at: boardPairingStore.fileURL)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
        }

        /// Two remote boards: "fz-A" / "fz-B".
        func stubTwoRemoteBoards() {
            let json = """
            [
              {"id":"fz-A","name":"Alpha","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}},
              {"id":"fz-B","name":"Beta","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
            ]
            """
            mock.handler = { req in
                switch (req.httpMethod, req.url?.path) {
                case ("GET", let p?) where p.hasSuffix("/boards"):
                    return (json.data(using: .utf8)!, .ok(for: req))
                default:
                    return (Data(), .response(for: req, status: 500))
                }
            }
        }
    }

    @Test("load reconciles a paired board, a local-only board, and a remote-only board")
    func loadReconciles() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()

        // One local board paired to fz-A, one local board unpaired.
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        _ = repo.createBoard(name: "Solo")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()

        #expect(model.state == .loaded)
        #expect(model.rows.filter { $0.kind == .paired }.count == 1)
        #expect(model.rows.filter { $0.kind == .localOnly }.count == 1)   // "Solo"
        #expect(model.rows.filter { $0.kind == .remoteOnly }.count == 1)  // fz-B
    }

    @Test("remote failure surfaces .error but still shows cached paired + local rows")
    func loadErrorKeepsCachedRows() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.mock.handler = { req in (Data(), .response(for: req, status: 500)) }

        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()

        if case .error = model.state {} else { Issue.record("expected .error state") }
        #expect(model.rows.contains { $0.kind == .paired })       // cached pairing still rendered
        #expect(model.rows.allSatisfy { $0.kind != .remoteOnly }) // no remote data
    }
}

@Suite("FizzyBoardBrowserViewModel actions", .serialized)
@MainActor
struct FizzyBoardBrowserViewModelActionTests {

    @Test("toggleSync flips the paired row's syncEnabled and refreshes")
    func toggleFlipsAndRefreshes() async throws {
        let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()
        let row = try #require(model.rows.first { $0.kind == .paired })
        #expect(row.syncEnabled == true)

        model.toggleSync(row)

        #expect(h.boardPairingStore.pairing(forLocal: alpha.id!)?.syncEnabled == false)
        #expect(model.rows.first { $0.kind == .paired }?.syncEnabled == false)  // row reprojected
    }

    @Test("unpair removes the pairing row and never deletes the local board")
    func unpairKeepsLocalBoard() async throws {
        let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()
        let row = try #require(model.rows.first { $0.kind == .paired })

        model.unpair(row)

        #expect(h.boardPairingStore.pairing(forLocal: alpha.id!) == nil)         // pairing gone
        let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
        #expect(boards.contains { $0.id == alpha.id! })                          // board kept
        // Alpha now reconciles as local-only.
        #expect(model.rows.contains { $0.kind == .localOnly && $0.localBoardID == alpha.id! })
    }
}
