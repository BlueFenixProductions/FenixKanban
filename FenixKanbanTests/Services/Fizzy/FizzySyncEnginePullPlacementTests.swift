import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Task #48 — per-column card pull with column placement.
///
/// The board-wide list `GET /cards?board_ids[]=` carries no `column` (or
/// `assignees`) per the wire fixtures, so a pull placed every new card into
/// an arbitrary column. The engine must instead fetch cards per column via
/// `GET /boards/:id/columns/:column_id/cards` and place each card in the
/// column it was served under.
///
/// That endpoint also excludes closed/not-now cards (per Fizzy docs), so a
/// paired card missing from the lists is NOT proof of server-side deletion:
/// the engine must confirm via `GET /cards/:number` — 404 means deleted,
/// 200 means alive (closed/postponed) and the local card must survive.
@Suite("FizzySyncEngine — per-column pull placement", .serialized)
@MainActor
struct FizzySyncEnginePullPlacementTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let pairingStore: FizzyCardPairingStore

        @MainActor
        init(localColumnName: String = "Triage") {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
            )
            cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: localColumnName)
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.placement.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.placement.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

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
                mapping: mapping,
                context: persistence.viewContext,
                pairingStore: pairingStore
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
        }

        func localColumn(fizzyID: String) -> Column? {
            let columns: [Column] = (board.columns as? Set<Column>).map { Array($0) } ?? []
            return columns.first { $0.fizzyColumnID == fizzyID }
        }

        func allLocalCards() -> [Card] {
            let columns: [Column] = (board.columns as? Set<Column>).map { Array($0) } ?? []
            return columns.flatMap { (($0.cards as? Set<Card>).map { Array($0) }) ?? [] }
        }
    }

    private static func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: MockURLProtocol.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let flatURL = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: flatURL)
        }
        // Source-directory fallback (matches FizzyDTOTests.loadFixture):
        // …/FenixKanbanTests/Services/Fizzy/ThisFile.swift → …/FenixKanbanTests/Fixtures/fizzy/
        let fixturePath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: fixturePath.path) {
            return try Data(contentsOf: fixturePath)
        }
        Issue.record("Could not locate fixture \(name).json (last tried \(fixturePath.path))")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Routes requests the way the live server shapes them:
    /// - `/boards/:id/columns` → columns list
    /// - `/boards/:id/columns/:col/cards` → per-column cards (column field present)
    /// - `/cards?board_ids[]=` (legacy board-wide list) → cards WITHOUT
    ///   `column`/`assignees` keys — the real wire shape for that endpoint
    /// - `/cards/:number` → single-card detail (or 404)
    /// - `/my/pins` → empty
    private static func routedHandler(
        columnsJSON: String,
        cardsByColumnID: [String: Data],
        legacyCardsJSON: String,
        cardDetailByNumber: [String: (Int, Data)] = [:]
    ) -> (URLRequest) throws -> (Data, HTTPURLResponse) {
        { req in
            let path = req.url?.path ?? ""
            switch req.httpMethod {
            case "GET" where path.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case "GET" where path.hasSuffix("/columns"):
                return (Data(columnsJSON.utf8), .ok(for: req))
            case "GET" where path.contains("/columns/") && path.hasSuffix("/cards"):
                let columnID = path
                    .components(separatedBy: "/columns/").last?
                    .components(separatedBy: "/cards").first ?? ""
                let data = cardsByColumnID[columnID] ?? Data("[]".utf8)
                return (data, .ok(for: req))
            case "GET" where path.hasSuffix("/cards"):
                // Legacy board-wide list (`?board_ids[]=` arrives as query).
                return (Data(legacyCardsJSON.utf8), .ok(for: req))
            case "GET" where path.contains("/cards/"):
                let number = path.components(separatedBy: "/cards/").last ?? ""
                if let (status, data) = cardDetailByNumber[number] {
                    return (data, status == 200 ? .ok(for: req) : .response(for: req, status: status))
                }
                return (Data(), .response(for: req, status: 404))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(path)")
                return (Data(), .response(for: req, status: 500))
            }
        }
    }

    // Minimal realistic per-column card JSON (column-cards wire shape).
    private static func columnCardJSON(
        id: String, number: Int, title: String,
        columnID: String, columnName: String,
        lastActiveAt: String = "2026-05-25T00:00:00Z"
    ) -> String {
        """
        {"id":"\(id)","number":\(number),"title":"\(title)","status":"published",
         "description":null,"description_html":null,"image_url":null,
         "has_attachments":false,"tags":[],"closed":false,"postponed":false,
         "golden":false,"last_active_at":"\(lastActiveAt)",
         "created_at":"2026-05-25T00:00:00Z",
         "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)",
         "column":{"id":"\(columnID)","name":"\(columnName)",
                   "color":"var(--color-card-4)","created_at":"2026-05-25T00:00:00Z"}}
        """
    }

    // Legacy board-wide list shape: NO column, NO assignees, NO closed keys.
    private static func legacyCardJSON(id: String, number: Int, title: String) -> String {
        """
        {"id":"\(id)","number":\(number),"title":"\(title)","status":"published",
         "description":null,"description_html":null,"image_url":null,
         "has_attachments":false,"tags":[],"golden":false,
         "last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z",
         "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)"}
        """
    }

    // MARK: - First sync (replace local)

    @Test("replaceLocal places each pulled card in its source column and pairs column IDs")
    func replaceLocalPlacesBySourceColumn() async throws {
        let h = Harness(localColumnName: "To Do")
        defer { h.tearDown() }

        // Remote: two columns. FCA is matched-by-name to the local "To Do";
        // the second is the VERBATIM column_cards_doc.json fixture's column.
        let fixtureColumnID = "03f5v9zkft4hj9qq0lsn9ohcn"
        let columnsJSON = """
        [
          {"id":"FCA","name":"To Do","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"},
          {"id":"\(fixtureColumnID)","name":"In Progress","color":{"name":"Lime","value":"y"},"created_at":"2026-05-25T00:00:00Z"}
        ]
        """
        let fixtureCards = try Self.loadFixture("column_cards_doc")
        h.mock.handler = Self.routedHandler(
            columnsJSON: columnsJSON,
            cardsByColumnID: [
                "FCA": Data("[\(Self.columnCardJSON(id: "fzA", number: 10, title: "Alpha", columnID: "FCA", columnName: "To Do"))]".utf8),
                fixtureColumnID: fixtureCards,
            ],
            legacyCardsJSON: "[\(Self.legacyCardJSON(id: "fzA", number: 10, title: "Alpha")),\(Self.legacyCardJSON(id: "03f5vaeq985jlvwv3arl4srq2", number: 1, title: "First!"))]"
        )

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)
        #expect(result.errors.isEmpty)
        #expect(result.itemsCreated == 2)

        // The engine must have used the per-column endpoint.
        let paths = h.mock.requests.compactMap { $0.url?.path }
        #expect(paths.contains { $0.hasSuffix("/boards/FB1/columns/FCA/cards") },
                "cards must be fetched per column, got: \(paths)")

        // Columns are paired by fizzy column ID…
        let toDo = try #require(h.localColumn(fizzyID: "FCA"))
        let inProgress = try #require(h.localColumn(fizzyID: fixtureColumnID))
        #expect(toDo.name == "To Do")
        #expect(inProgress.name == "In Progress")

        // …and each card landed in the column it was served under.
        let toDoTitles = Set(((toDo.cards as? Set<Card>) ?? []).compactMap(\.title))
        let inProgressTitles = Set(((inProgress.cards as? Set<Card>) ?? []).compactMap(\.title))
        #expect(toDoTitles == ["Alpha"])
        #expect(inProgressTitles == ["First!"])
    }

    // MARK: - Steady state

    @Test("steady state: remote column move pulls when local is untouched")
    func steadyStateRemoteMovePulls() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Mover")
        try h.persistence.viewContext.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz9", fizzyNumber: 9, fizzyUpdatedAt: t0),
            for: card.id!
        )
        card.modifiedAt = t0 // local untouched since last sync

        // Remote: card fz9 now lives in column FC2 ("Doing"), newer than t0.
        let columnsJSON = """
        [
          {"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"},
          {"id":"FC2","name":"Doing","color":{"name":"Lime","value":"y"},"created_at":"2026-05-25T00:00:00Z"}
        ]
        """
        let moved = Self.columnCardJSON(
            id: "fz9", number: 9, title: "Mover",
            columnID: "FC2", columnName: "Doing",
            lastActiveAt: "2026-06-12T00:00:00Z"
        )
        h.mock.handler = Self.routedHandler(
            columnsJSON: columnsJSON,
            cardsByColumnID: ["FC1": Data("[]".utf8), "FC2": Data("[\(moved)]".utf8)],
            legacyCardsJSON: "[\(Self.legacyCardJSON(id: "fz9", number: 9, title: "Mover"))]"
        )

        let result = try await h.engine.sync()
        #expect(result.errors.isEmpty)

        #expect(card.column?.fizzyColumnID == "FC2",
                "remote column move must be pulled when local is untouched")
        // The move is a pull — it must not re-trigger a push next cycle.
        #expect(card.modifiedAt == Date.fizzyISO8601("2026-06-12T00:00:00Z"))
    }

    @Test("steady state: paired card absent from lists but alive (closed) is NOT deleted")
    func steadyStateClosedCardSurvives() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Closed Remotely")
        try h.persistence.viewContext.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz7", fizzyNumber: 7, fizzyUpdatedAt: t0),
            for: card.id!
        )
        card.modifiedAt = t0

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        // Single-card doc: alive, closed. (Closed cards drop out of the
        // per-column lists; only this endpoint can prove the card exists.)
        let closedDetail = """
        {"id":"fz7","number":7,"title":"Closed Remotely","status":"published",
         "description":null,"description_html":null,"image_url":null,
         "has_attachments":false,"tags":[],"closed":true,"golden":false,
         "last_active_at":"2026-06-12T00:00:00Z","created_at":"2026-05-25T00:00:00Z",
         "url":"https://fizzy.bluefenix.net/ACCT/cards/7","column":null}
        """
        h.mock.handler = Self.routedHandler(
            columnsJSON: columnsJSON,
            cardsByColumnID: ["FC1": Data("[]".utf8)],
            legacyCardsJSON: "[]",
            cardDetailByNumber: ["7": (200, Data(closedDetail.utf8))]
        )

        let result = try await h.engine.sync()
        #expect(result.errors.isEmpty)
        #expect(result.itemsDeleted == 0)
        #expect(h.allLocalCards().compactMap(\.title) == ["Closed Remotely"],
                "a closed-but-alive remote card must survive the sync")
    }

    @Test("steady state: paired card absent from lists and 404 on detail IS deleted")
    func steadyStateGoneCardDeletes() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Gone")
        try h.persistence.viewContext.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz5", fizzyNumber: 5, fizzyUpdatedAt: t0),
            for: card.id!
        )
        card.modifiedAt = t0

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        h.mock.handler = Self.routedHandler(
            columnsJSON: columnsJSON,
            cardsByColumnID: ["FC1": Data("[]".utf8)],
            legacyCardsJSON: "[]",
            cardDetailByNumber: ["5": (404, Data())]
        )

        let result = try await h.engine.sync()
        #expect(result.itemsDeleted == 1)
        #expect(result.errors.isEmpty)
        #expect(h.allLocalCards().isEmpty, "a 404'd remote card must be deleted locally")
        // Resurrection guard: the deleted card must NOT be POSTed back by the
        // push loop (its pairing was removed mid-cycle; the pre-delete
        // localCards snapshot still contains it).
        #expect(!h.mock.requests.contains { $0.httpMethod == "POST" },
                "a just-deleted card must not be pushed back to the server")
    }
}

private extension Date {
    /// Strict ISO-8601-with-fractional-seconds parse for test literals.
    static func fizzyISO8601(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)!
    }
}
