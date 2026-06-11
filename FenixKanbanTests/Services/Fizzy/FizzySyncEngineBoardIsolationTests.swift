import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncEngine — board isolation", .serialized)
@MainActor
struct FizzySyncEngineBoardIsolationTests {

    /// Builds a fresh in-memory store with 3 local boards (3 columns, 5 cards each).
    /// Pairs board[0] with fizzy `FB1`. Returns the configured engine + harnesses
    /// for asserting on the OTHER boards.
    private struct Harness {
        let persistence: PersistenceController
        let boards: [Board]
        let engine: FizzySyncEngine
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let suiteName: String
        let pairingStore: FizzyCardPairingStore

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            let boardRepo = BoardRepository(context: persistence.viewContext)
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
            )
            let cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)

            var built: [Board] = []
            for b in 0..<3 {
                let board = boardRepo.createBoard(name: "Board \(b)")
                for c in 0..<3 {
                    let col = boardRepo.createColumn(in: board, name: "Col \(c)")
                    for k in 0..<5 {
                        _ = cardRepo.createCard(in: col, title: "B\(b)-C\(c)-K\(k)")
                    }
                }
                built.append(board)
            }
            try! persistence.viewContext.save()
            boards = built

            let prefix = "test.fizzy.isolate.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.isolate.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: built[0].id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t", accountSlug: "ACCT",
                urlSession: session, clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client, authState: authState, mapping: mapping,
                context: persistence.viewContext, pairingStore: pairingStore
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
            MockURLProtocol.reset()
        }

        func cardCount(on board: Board) -> Int {
            ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
                sum + (((col.cards as? Set<Card>) ?? []).count)
            }
        }
    }

    @Test("syncFirst(.pushLocalToFizzy) does not touch other boards")
    func pushIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let body = """
                {"id":"fz-x","number":1,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(h.cardCount(on: h.boards[1]) == 15)
        #expect(h.cardCount(on: h.boards[2]) == 15)

        // No fizzyID stamped on non-paired boards' cards.
        let board1FizzyIDs = ((h.boards[1].columns as? Set<Column>) ?? [])
            .flatMap { ($0.cards as? Set<Card>) ?? [] }
            .compactMap(\.fizzyID)
        let board2FizzyIDs = ((h.boards[2].columns as? Set<Column>) ?? [])
            .flatMap { ($0.cards as? Set<Card>) ?? [] }
            .compactMap(\.fizzyID)
        #expect(board1FizzyIDs.isEmpty)
        #expect(board2FizzyIDs.isEmpty)
    }

    @Test("syncFirst(.replaceLocalWithFizzy) does not touch other boards")
    func replaceIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Todo","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"R1","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"},
          {"id":"fz2","number":2,"title":"R2","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/2"}
        ]
        """
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(h.cardCount(on: h.boards[0]) == 2, "paired board replaced")
        #expect(h.cardCount(on: h.boards[1]) == 15, "non-paired board untouched")
        #expect(h.cardCount(on: h.boards[2]) == 15, "non-paired board untouched")
    }

    @Test("syncFirst(.mergeIfNoConflicts) does not touch other boards")
    func mergeIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Col 0","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz-new","number":1,"title":"New from remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/9"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/9"):
                let body = """
                {"id":"fz-9","number":9,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(h.cardCount(on: h.boards[1]) == 15, "non-paired board untouched")
        #expect(h.cardCount(on: h.boards[2]) == 15, "non-paired board untouched")
    }

    @Test("sync() steady-state does not touch other boards")
    func steadyStateIsolates() async throws {
        let h = Harness(); defer { h.tearDown() }

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let body = """
                {"id":"fz-1","number":1,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.sync()

        #expect(h.cardCount(on: h.boards[1]) == 15)
        #expect(h.cardCount(on: h.boards[2]) == 15)

        let nonPairedFizzyIDs = (h.boards[1...2]).flatMap { board -> [String] in
            ((board.columns as? Set<Column>) ?? [])
                .flatMap { ($0.cards as? Set<Card>) ?? [] }
                .compactMap(\.fizzyID)
        }
        #expect(nonPairedFizzyIDs.isEmpty)
    }
}
