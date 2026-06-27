import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - File-scope fixtures (the URLProtocol handler runs off-actor)

private let lifecycleColumnsJSON = """
[{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
"""

private func lifecycleCardJSON(
    id: String, number: Int, title: String,
    closed: Bool = false, postponed: Bool = false,
    lastActiveAt: String = "2026-05-25T00:00:00Z",
    inColumn: Bool = true
) -> String {
    """
    {"id":"\(id)","number":\(number),"title":"\(title)","status":"published",
     "description":null,"description_html":null,"image_url":null,
     "has_attachments":false,"tags":[],"closed":\(closed),"postponed":\(postponed),
     "golden":false,"last_active_at":"\(lastActiveAt)",
     "created_at":"2026-05-25T00:00:00Z",
     "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)"\(inColumn ? ",\n     \"column\":{\"id\":\"FC1\",\"name\":\"Triage\",\"color\":\"var(--color-card-4)\",\"created_at\":\"2026-05-25T00:00:00Z\"}" : ",\n     \"column\":null")}
    """
}

/// One column; configurable listed cards + per-number single-card details.
private final class LifecycleBoard: @unchecked Sendable {
    var listedCardsJSON: String
    var detailByNumber: [String: (status: Int, json: String)]

    init(listedCardsJSON: String, detailByNumber: [String: (Int, String)] = [:]) {
        self.listedCardsJSON = listedCardsJSON
        self.detailByNumber = detailByNumber
    }

    func handler(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = req.url?.path ?? ""
        switch req.httpMethod {
        case "GET" where path.hasSuffix("/my/pins"):
            return (Data("[]".utf8), .ok(for: req))
        case "GET" where path.hasSuffix("/columns"):
            return (Data(lifecycleColumnsJSON.utf8), .ok(for: req))
        case "GET" where path.contains("/columns/") && path.hasSuffix("/cards"):
            return (Data(listedCardsJSON.utf8), .ok(for: req))
        case "GET" where path.contains("/cards/"):
            let number = path.components(separatedBy: "/cards/").last ?? ""
            if let (status, json) = detailByNumber[number] {
                return (Data(json.utf8), status == 200 ? .ok(for: req) : .response(for: req, status: status))
            }
            return (Data(), .response(for: req, status: 404))
        default:
            Issue.record("unexpected request: \(req.httpMethod ?? "?") \(path)")
            return (Data(), .response(for: req, status: 500))
        }
    }
}

// MARK: - Suite

/// Task #67 — card lifecycle sync (issue #13).
///
/// Fizzy's per-column lists carry only active cards. Task #48's deletion
/// guard already confirms unlisted cards via `GET /cards/:number`; this
/// task makes the guard TRANSITION them: `closed: true` → `.closed`,
/// `postponed: true` → `.notNow` — and `applyRemote` maps the wire fields
/// so a reopened card pulls back to `.active`.
@Suite("FizzySyncEngine — lifecycle sync", .serialized)
@MainActor
struct FizzySyncEngineLifecycleTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let authState: FizzyAuthState
        let boardPairingStore: FizzyBoardPairingStore
        let pairingStore: FizzyCardPairingStore

        @MainActor
        init() {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
            )
            cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: "Triage")
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.lifecycle.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            boardPairingStore = FizzyBoardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-board-pairings-\(UUID().uuidString).json")
            )
            boardPairingStore.upsert(FizzyBoardPairing(localBoardID: board.id!, fizzyBoardID: "FB1"))

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
                boardPairingStore: boardPairingStore,
                context: persistence.viewContext,
                pairingStore: pairingStore
            )
        }

        func tearDown() {
            authState.clear()
            try? FileManager.default.removeItem(at: boardPairingStore.fileURL)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
        }

        /// Seeds a local card paired to remote (fizzyID/number) at t0.
        func seedPairedCard(title: String, fizzyID: String, number: Int64, at t0: Date) -> Card {
            let card = cardRepo.createCard(in: column, title: title)
            try! persistence.viewContext.save()
            pairingStore.setPairing(
                FizzyCardPairing(fizzyID: fizzyID, fizzyNumber: number, fizzyUpdatedAt: t0),
                for: card.id!
            )
            card.modifiedAt = t0
            return card
        }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("remotely-closed card transitions to .closed (not deleted) via the detail guard")
    func remoteCloseTransitionsLocal() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedPairedCard(title: "Done thing", fizzyID: "fz7", number: 7, at: Self.t0)

        let board = LifecycleBoard(
            listedCardsJSON: "[]",
            detailByNumber: ["7": (200, lifecycleCardJSON(
                id: "fz7", number: 7, title: "Done thing",
                closed: true, lastActiveAt: "2026-06-12T03:00:00Z", inColumn: false))]
        )
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)
        #expect(result.itemsDeleted == 0)
        #expect(result.itemsUpdated >= 1)
        #expect(card.lifecycleStatus == .closed)
        #expect(card.closedAt != nil)
        #expect(card.isDeleted == false)
    }

    @Test("remotely-postponed card transitions to .notNow")
    func remotePostponeTransitionsLocal() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedPairedCard(title: "Later thing", fizzyID: "fz8", number: 8, at: Self.t0)

        let board = LifecycleBoard(
            listedCardsJSON: "[]",
            detailByNumber: ["8": (200, lifecycleCardJSON(
                id: "fz8", number: 8, title: "Later thing",
                postponed: true, lastActiveAt: "2026-06-12T03:00:00Z", inColumn: false))]
        )
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)
        #expect(card.lifecycleStatus == .notNow)
        #expect(card.closedAt == nil)
        #expect(card.isDeleted == false)
    }

    @Test("reopened card pulls back to .active when it reappears in the lists")
    func remoteReopenPullsActive() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedPairedCard(title: "Back again", fizzyID: "fz9", number: 9, at: Self.t0)
        card.lifecycleStatus = .closed // closed in an earlier cycle

        let board = LifecycleBoard(
            listedCardsJSON: "[\(lifecycleCardJSON(id: "fz9", number: 9, title: "Back again", lastActiveAt: "2026-06-12T04:00:00Z"))]"
        )
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)
        #expect(card.lifecycleStatus == .active)
        #expect(card.closedAt == nil)
    }

    @Test("lifecycle transitions do not echo-push on the following cycle")
    func lifecycleTransitionDoesNotEchoPush() async throws {
        let h = Harness()
        defer { h.tearDown() }
        _ = h.seedPairedCard(title: "Done thing", fizzyID: "fz7", number: 7, at: Self.t0)

        let board = LifecycleBoard(
            listedCardsJSON: "[]",
            detailByNumber: ["7": (200, lifecycleCardJSON(
                id: "fz7", number: 7, title: "Done thing",
                closed: true, lastActiveAt: "2026-06-12T03:00:00Z", inColumn: false))]
        )
        h.mock.handler = { try board.handler($0) }

        _ = try await h.engine.sync(localBoardID: h.board.id!) // transition cycle
        let second = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(second.errors.isEmpty)
        let didPush = h.mock.requests.contains {
            ($0.httpMethod == "PUT" || $0.httpMethod == "POST") && ($0.url?.path.contains("/cards") ?? false)
        }
        #expect(!didPush, "pulled lifecycle changes must not trigger PUT/POST")
    }

    @Test("locally-edited unlisted card keeps its content but still transitions lifecycle")
    func localEditsSurviveLifecycleTransition() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedPairedCard(title: "Original", fizzyID: "fz7", number: 7, at: Self.t0)
        // Local edit AFTER the last sync: content must win over the remote doc.
        card.title = "Locally edited"
        card.modifiedAt = Self.t0.addingTimeInterval(120)

        let board = LifecycleBoard(
            listedCardsJSON: "[]",
            detailByNumber: ["7": (200, lifecycleCardJSON(
                id: "fz7", number: 7, title: "Remote title",
                closed: true, lastActiveAt: "2026-06-12T03:00:00Z", inColumn: false))]
        )
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)
        #expect(card.lifecycleStatus == .closed, "lifecycle still transitions")
        #expect(card.title == "Locally edited", "local content edit must not be clobbered")
    }
}
