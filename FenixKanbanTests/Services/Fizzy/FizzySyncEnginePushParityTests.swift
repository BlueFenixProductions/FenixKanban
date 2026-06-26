import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - File-scope fixtures (URLProtocol handler runs off-actor)

private let parityColumnsJSON = """
[
  {"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"},
  {"id":"FC2","name":"Doing","color":{"name":"Lime","value":"y"},"created_at":"2026-05-25T00:00:00Z"}
]
"""

private func parityCardJSON(
    id: String, number: Int, title: String,
    columnID: String = "FC1", columnName: String = "Triage",
    tags: [String] = [], assigneeIDs: [String] = [],
    lastActiveAt: String = "2026-05-25T00:00:00Z"
) -> String {
    let tagsJSON = tags.map { "\"\($0)\"" }.joined(separator: ",")
    let assigneesJSON = assigneeIDs.map {
        """
        {"id":"\($0)","name":"User \($0)","role":"member","active":true,
         "email_address":"\($0)@example.com","created_at":"2026-05-25T00:00:00Z",
         "url":null,"avatar_url":null}
        """
    }.joined(separator: ",")
    return """
    {"id":"\(id)","number":\(number),"title":"\(title)","status":"published",
     "description":null,"description_html":null,"image_url":null,
     "has_attachments":false,"tags":[\(tagsJSON)],"closed":false,"postponed":false,
     "golden":false,"last_active_at":"\(lastActiveAt)",
     "created_at":"2026-05-25T00:00:00Z",
     "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)",
     "column":{"id":"\(columnID)","name":"\(columnName)","color":"var(--color-card-4)","created_at":"2026-05-25T00:00:00Z"},
     "assignees":[\(assigneesJSON)]}
    """
}

/// Records mutation requests (method, path, body) for exact-diff assertions.
private final class ParityBoard: @unchecked Sendable {
    let cardsJSON: String
    private let lock = NSLock()
    private var _mutations: [(method: String, path: String, body: String)] = []
    var mutations: [(method: String, path: String, body: String)] {
        lock.lock(); defer { lock.unlock() }; return _mutations
    }

    init(cardsJSON: String) { self.cardsJSON = cardsJSON }

    func handler(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "?"
        switch method {
        case "GET" where path.hasSuffix("/my/pins"):
            return (Data("[]".utf8), .ok(for: req))
        case "GET" where path.hasSuffix("/columns"):
            return (Data(parityColumnsJSON.utf8), .ok(for: req))
        case "GET" where path.contains("/columns/") && path.hasSuffix("/cards"):
            let columnID = path.components(separatedBy: "/columns/").last?
                .components(separatedBy: "/cards").first ?? ""
            return (Data((columnID == "FC1" ? cardsJSON : "[]").utf8), .ok(for: req))
        case "PUT" where path.contains("/cards/"):
            record(method, path, req)
            // Echo the updated card so the push can record lastActiveAt.
            return (Data(parityCardJSON(id: "fz9", number: 9, title: "Edited", lastActiveAt: "2026-06-12T05:00:00Z").utf8), .ok(for: req))
        case "POST" where path.contains("/taggings") || path.contains("/triage") || path.contains("/assignments"):
            record(method, path, req)
            return (Data(), .response(for: req, status: 204))
        default:
            Issue.record("unexpected request: \(method) \(path)")
            return (Data(), .response(for: req, status: 500))
        }
    }

    private func record(_ method: String, _ path: String, _ req: URLRequest) {
        let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        } ?? Data()
        lock.lock(); defer { lock.unlock() }
        _mutations.append((method, path, String(data: body, encoding: .utf8) ?? ""))
    }
}

// MARK: - Suite

/// Task #69 — push parity (C4b/C5/C6): local card moves, tag edits, and
/// assignee edits reach the server on the LWW local-newer branch.
///
/// Wire facts (live-probed 2026-06-12, docs/fizzy-api-notes.md): moves push
/// via `POST /cards/:n/triage {column_id}`; `tag_ids` on PUT is rejected →
/// tags push as EXACT toggle diffs via `POST /taggings {tag_title}` (toggles
/// are not idempotent); assignments toggle symmetrically via
/// `POST /assignments {assignee_id}`.
@Suite("FizzySyncEngine — push parity (move/tags/assignees)", .serialized)
@MainActor
struct FizzySyncEnginePushParityTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let triage: Column
        let doing: Column
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
            triage = boardRepo.createColumn(in: board, name: "Triage")
            doing = boardRepo.createColumn(in: board, name: "Doing")
            triage.fizzyColumnID = "FC1"
            doing.fizzyColumnID = "FC2"
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.parity.\(UUID().uuidString)"
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

        /// Local card paired to remote fz9/#9 at t0, locally edited at t0+120.
        func seedLocallyNewerCard(in column: Column, title: String = "Edited") -> Card {
            let t0 = Date(timeIntervalSince1970: 1_750_000_000)
            let card = cardRepo.createCard(in: column, title: title)
            try! persistence.viewContext.save()
            pairingStore.setPairing(
                FizzyCardPairing(fizzyID: "fz9", fizzyNumber: 9, fizzyUpdatedAt: t0),
                for: card.id!
            )
            card.modifiedAt = t0.addingTimeInterval(120)
            return card
        }
    }

    @Test("local column move pushes POST /cards/:n/triage with the new column id")
    func localMovePushesTriage() async throws {
        let h = Harness()
        defer { h.tearDown() }
        // Local card sits in Doing (FC2); remote still lists it under FC1.
        _ = h.seedLocallyNewerCard(in: h.doing)
        let board = ParityBoard(cardsJSON: "[\(parityCardJSON(id: "fz9", number: 9, title: "Edited"))]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)

        let triages = board.mutations.filter { $0.path.hasSuffix("/cards/9/triage") }
        #expect(triages.count == 1)
        #expect(triages.first?.body.contains("FC2") == true,
                "triage body must carry the local column id, got: \(triages.first?.body ?? "")")
    }

    @Test("local tag edits push exact toggle diffs (add missing, remove extra)")
    func localTagEditsPushToggleDiffs() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedLocallyNewerCard(in: h.triage)
        // Local labels: alpha, beta. Remote tags: alpha, gamma.
        let labelRepo = LabelRepository(context: h.persistence.viewContext)
        let alpha = labelRepo.createLabel(name: "alpha", colorHex: "#808080")
        let beta = labelRepo.createLabel(name: "beta", colorHex: "#808080")
        card.labels = NSSet(array: [alpha, beta])
        let board = ParityBoard(cardsJSON: "[\(parityCardJSON(id: "fz9", number: 9, title: "Edited", tags: ["alpha", "gamma"]))]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)

        let toggles = board.mutations.filter { $0.path.hasSuffix("/cards/9/taggings") }
        let bodies = Set(toggles.map(\.body))
        #expect(toggles.count == 2, "exactly two toggles (beta on, gamma off), got: \(toggles)")
        #expect(bodies.contains { $0.contains("beta") })
        #expect(bodies.contains { $0.contains("gamma") })
        #expect(!bodies.contains { $0.contains("alpha") }, "alpha matches both sides — toggling it would REMOVE it")
    }

    @Test("local assignee edits push exact toggle diffs")
    func localAssigneeEditsPushToggleDiffs() async throws {
        let h = Harness()
        defer { h.tearDown() }
        let card = h.seedLocallyNewerCard(in: h.triage)
        card.assignees = [CardAssignee(id: "u1", name: "User u1")]
        // Remote has u2 assigned.
        let board = ParityBoard(cardsJSON: "[\(parityCardJSON(id: "fz9", number: 9, title: "Edited", assigneeIDs: ["u2"]))]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)

        let toggles = board.mutations.filter { $0.path.hasSuffix("/cards/9/assignments") }
        let bodies = Set(toggles.map(\.body))
        #expect(toggles.count == 2, "exactly two toggles (u1 on, u2 off), got: \(toggles)")
        #expect(bodies.contains { $0.contains("u1") })
        #expect(bodies.contains { $0.contains("u2") })
    }

    @Test("no diffs → PUT only, zero triage/tagging/assignment calls (pin)")
    func noDiffsMeansNoToggles() async throws {
        let h = Harness()
        defer { h.tearDown() }
        _ = h.seedLocallyNewerCard(in: h.triage)
        let board = ParityBoard(cardsJSON: "[\(parityCardJSON(id: "fz9", number: 9, title: "Edited"))]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)
        #expect(result.errors.isEmpty)

        let extras = board.mutations.filter { !$0.path.hasSuffix("/cards/9") }
        #expect(extras.isEmpty, "no toggles expected, got: \(extras)")
        #expect(board.mutations.contains { $0.method == "PUT" })
    }
}
