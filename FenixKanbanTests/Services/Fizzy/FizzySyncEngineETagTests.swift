import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - File-scope fixtures (the URLProtocol handler runs off-actor)

private let etagColumnsJSON = """
[{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
"""

private func etagCardJSON(
    id: String, number: Int, title: String, lastActiveAt: String = "2026-05-25T00:00:00Z"
) -> String {
    """
    {"id":"\(id)","number":\(number),"title":"\(title)","status":"published",
     "description":null,"description_html":null,"image_url":null,
     "has_attachments":false,"tags":[],"closed":false,"postponed":false,
     "golden":false,"last_active_at":"\(lastActiveAt)",
     "created_at":"2026-05-25T00:00:00Z",
     "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)",
     "column":{"id":"FC1","name":"Triage","color":"var(--color-card-4)","created_at":"2026-05-25T00:00:00Z"}}
    """
}

/// Handler serving one column whose card list carries an ETag. When a
/// request arrives with `If-None-Match` equal to the current etag, answers
/// 304 with no body — like the live server.
private final class ETagBoard: @unchecked Sendable {
    var etag = "\"v1\""
    var cardsJSON: String
    var conditionalHits = 0
    var fullFetches = 0

    init(cardsJSON: String) { self.cardsJSON = cardsJSON }

    func handler(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = req.url?.path ?? ""
        switch req.httpMethod {
        case "GET" where path.hasSuffix("/my/pins"):
            return (Data("[]".utf8), .ok(for: req))
        case "GET" where path.hasSuffix("/columns"):
            return (Data(etagColumnsJSON.utf8), .ok(for: req))
        case "GET" where path.contains("/columns/") && path.hasSuffix("/cards"):
            if req.value(forHTTPHeaderField: "If-None-Match") == etag {
                conditionalHits += 1
                return (Data(), .response(for: req, status: 304, headers: ["ETag": etag]))
            }
            fullFetches += 1
            return (Data(cardsJSON.utf8), .ok(for: req, headers: ["ETag": etag]))
        case "PUT" where path.contains("/cards/"):
            // Echo an updated card for LWW pushes.
            return (Data(etagCardJSON(id: "fz1", number: 1, title: "Edited", lastActiveAt: "2026-06-12T01:00:00Z").utf8), .ok(for: req))
        default:
            Issue.record("unexpected request: \(req.httpMethod ?? "?") \(path)")
            return (Data(), .response(for: req, status: 500))
        }
    }
}

// MARK: - Suite

/// Task #61 — ETag-conditional card pulls (C2).
///
/// Steady-state polling (every 5 min via SyncScheduler) makes the common
/// no-change cycle the hot path. The engine now sends `If-None-Match` on
/// per-column card list fetches and, on 304, reuses the cached card list
/// from the previous cycle — so the remote "universe" stays complete and
/// the LWW / soft-delete / push logic runs unchanged against cached data.
///
/// Conservative grain: conditional requests are only sent when the prior
/// response was single-page (no `Link: rel="next"`); multi-page collections
/// always re-fetch fully (page-1-ETag semantics across pages unverified).
@Suite("FizzySyncEngine — ETag conditional pulls", .serialized)
@MainActor
struct FizzySyncEngineETagTests {

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

            let prefix = "test.fizzy.etag.\(UUID().uuidString)"
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
    }

    @Test("second no-change cycle sends If-None-Match, gets 304, and is a complete no-op")
    func unchangedCycleIs304NoOp() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let board = ETagBoard(cardsJSON: "[\(etagCardJSON(id: "fz1", number: 1, title: "One"))]")
        h.mock.handler = { try board.handler($0) }

        // Cycle 1: full fetch, pulls the remote card, caches list + etag.
        let first = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(first.errors.isEmpty)
        #expect(first.itemsCreated == 1)
        #expect(board.fullFetches == 1)

        // Cycle 2: nothing changed anywhere.
        let second = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(second.errors.isEmpty)
        #expect(board.conditionalHits == 1, "second cycle must send If-None-Match")
        #expect(board.fullFetches == 1, "no second full fetch on 304")
        #expect(second.itemsCreated == 0)
        #expect(second.itemsUpdated == 0)
        #expect(second.itemsDeleted == 0, "304 reuse must never look like remote deletion")

        // The pulled card survived both cycles.
        let cards = (h.column.cards as? Set<Card>) ?? []
        #expect(cards.compactMap(\.title) == ["One"])
    }

    @Test("304 cycle still pushes a local edit (push is not starved by the skipped pull)")
    func etag304StillPushesLocalEdits() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let board = ETagBoard(cardsJSON: "[\(etagCardJSON(id: "fz1", number: 1, title: "One"))]")
        h.mock.handler = { try board.handler($0) }

        _ = try await h.engine.sync(localBoardID: h.board.id!) // cycle 1: pull + cache

        // Local edit after the pull.
        let card = try #require(((h.column.cards as? Set<Card>) ?? []).first)
        card.title = "Edited"
        card.modifiedAt = Date(timeIntervalSinceNow: 60)

        let second = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(second.errors.isEmpty)
        #expect(board.conditionalHits == 1, "pull side still conditional")
        let didPut = h.mock.requests.contains { $0.httpMethod == "PUT" && ($0.url?.path.contains("/cards/1") ?? false) }
        #expect(didPut, "local edit must PUT even when the pull 304-skips")
    }

    @Test("remote change invalidates: changed etag yields full fetch and the update pulls")
    func remoteChangeRefetches() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let board = ETagBoard(cardsJSON: "[\(etagCardJSON(id: "fz1", number: 1, title: "One"))]")
        h.mock.handler = { try board.handler($0) }

        _ = try await h.engine.sync(localBoardID: h.board.id!) // cycle 1

        // Remote edit: new content, new etag — conditional request misses.
        board.cardsJSON = "[\(etagCardJSON(id: "fz1", number: 1, title: "Renamed", lastActiveAt: "2026-06-12T02:00:00Z"))]"
        board.etag = "\"v2\""

        let second = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(second.errors.isEmpty)
        #expect(board.fullFetches == 2, "etag miss must re-fetch")
        #expect(second.itemsUpdated == 1)
        let cards = (h.column.cards as? Set<Card>) ?? []
        #expect(cards.compactMap(\.title) == ["Renamed"])

        // And the NEW etag is cached: a third unchanged cycle 304s.
        let third = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(third.errors.isEmpty)
        #expect(board.conditionalHits >= 1)
        #expect(board.fullFetches == 2)
    }

    @Test("multi-page collections never send If-None-Match (conservative grain)")
    func multiPageSkipsConditional() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Page 1 carries a rel="next" link → engine must treat the
        // collection as multi-page and always re-fetch fully.
        let page1 = "[\(etagCardJSON(id: "fz1", number: 1, title: "One"))]"
        let page2 = "[\(etagCardJSON(id: "fz2", number: 2, title: "Two"))]"
        let state = ETagBoard(cardsJSON: page1)
        h.mock.handler = { req in
            let path = req.url?.path ?? ""
            let query = req.url?.query ?? ""
            if req.httpMethod == "GET", path.contains("/columns/"), path.hasSuffix("/cards") {
                #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil,
                        "multi-page collection must not go conditional")
                if query.contains("page=2") {
                    return (Data(page2.utf8), .ok(for: req, headers: ["ETag": "\"p2\""]))
                }
                state.fullFetches += 1
                let next = "<https://fizzy.bluefenix.net/ACCT/boards/FB1/columns/FC1/cards?page=2>; rel=\"next\""
                return (Data(page1.utf8), .ok(for: req, headers: ["ETag": "\"p1\"", "Link": next]))
            }
            return try state.handler(req)
        }

        _ = try await h.engine.sync(localBoardID: h.board.id!)
        _ = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(state.fullFetches == 2, "both cycles fetch fully for multi-page lists")
        let cards = (h.column.cards as? Set<Card>) ?? []
        #expect(Set(cards.compactMap(\.title)) == ["One", "Two"])
    }
}
