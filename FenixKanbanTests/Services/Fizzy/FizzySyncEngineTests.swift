import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncEngine — pairing precondition", .serialized)
@MainActor
struct FizzySyncEnginePairingTests {

    @Test("syncFirst returns an empty FizzySyncResult when unpaired")
    func unpairedReturnsEmpty() async throws {
        // Persistence + repos
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)

        // Auth + mapping using unique test prefixes/suites
        let authState = FizzyAuthState(keyPrefix: "test.fizzy.engine.\(UUID().uuidString)")
        defer { authState.clear() }
        let suiteName = "test.fizzy.engine.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)

        // Engine — not paired
        let client = FizzyClient(
            baseURL: URL(string: "https://example.invalid")!,
            accessToken: "t",
            accountSlug: "ACCT"
        )
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let engine = FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext,
            pairingStore: pairingStore
        )

        let result = try await engine.syncFirst(mode: .pushLocalToFizzy)
        #expect(result == FizzySyncResult())
    }
}

@Suite("FizzySyncEngine — first-sync mode 1 (push local)", .serialized)
@MainActor
struct FizzySyncEnginePushLocalTests {

    /// Shared test harness — builds a paired board + engine wired to MockURLProtocol.
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

            let prefix = "test.fizzy.push.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.push.mapping.\(UUID().uuidString)"
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
    }

    @Test("push mode: 2 local cards + empty remote → 2 POSTs, returned IDs stored")
    func pushEmptyRemote() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card1 = h.cardRepo.createCard(in: h.column, title: "First")
        let card2 = h.cardRepo.createCard(in: h.column, title: "Second")
        try h.persistence.viewContext.save()

        // Configure mock: 2 POSTs each returning 201+Location followed by a single-card GET.
        var postCount = 0
        var nextFizzyID = 100
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let id = nextFizzyID
                nextFizzyID += 1
                let location = "https://fizzy.bluefenix.net/ACCT/cards/\(id)"
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                // Location-follow: return a synthetic card with the requested number/id
                let number = (p as NSString).lastPathComponent
                let body = """
                {
                  "id": "fzid-\(number)",
                  "number": \(number),
                  "title": "x",
                  "status": "published",
                  "description": null,
                  "description_html": null,
                  "image_url": null,
                  "has_attachments": false,
                  "tags": [],
                  "golden": false,
                  "last_active_at": "2026-05-25T00:00:00Z",
                  "created_at": "2026-05-25T00:00:00Z",
                  "url": "https://fizzy.bluefenix.net/ACCT/cards/\(number)"
                }
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(postCount == 2)
        #expect(result.itemsCreated == 2)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)

        h.persistence.viewContext.refresh(card1, mergeChanges: false)
        h.persistence.viewContext.refresh(card2, mergeChanges: false)
        #expect(card1.fizzyID != nil)
        #expect(card2.fizzyID != nil)
        #expect(card1.fizzyID != card2.fizzyID)
    }

    @Test("push mode: only local cards with nil fizzyID get pushed")
    func pushSkipsAlreadyPaired() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let unpushed = h.cardRepo.createCard(in: h.column, title: "Unpushed")
        let alreadyPushed = h.cardRepo.createCard(in: h.column, title: "Already paired")
        alreadyPushed.fizzyID = "fz-existing"  // mark as already paired
        try h.persistence.viewContext.save()

        var postCount = 0
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/77"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/77"):
                let body = """
                {"id":"fzid-77","number":77,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/77"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(postCount == 1, "only the unpushed card should be POSTed")
        #expect(result.itemsCreated == 1)
        #expect(result.errors.isEmpty)

        h.persistence.viewContext.refresh(unpushed, mergeChanges: false)
        h.persistence.viewContext.refresh(alreadyPushed, mergeChanges: false)
        #expect(unpushed.fizzyID == "fzid-77")
        #expect(alreadyPushed.fizzyID == "fz-existing", "already-paired card's fizzyID is preserved")
    }
}

@Suite("FizzySyncEngine — first-sync mode 2 (replace local)", .serialized)
@MainActor
struct FizzySyncEngineReplaceLocalTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let labelRepo: LabelRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
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
            labelRepo = LabelRepository(context: persistence.viewContext)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: "Triage")
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.replace.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.replace.mapping.\(UUID().uuidString)"
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
    }

    /// Mock handler that returns the given remote state for columns + cards
    /// endpoints. The engine's remote-card fetch uses `/cards?board_ids[]=...`,
    /// which urlSession converts to `/cards` + query, so we match on path
    /// suffix `/cards` (NOT `.contains("?")`).
    private static func mockBoardState(columnsJSON: String, cardsJSON: String) -> (URLRequest) throws -> (Data, HTTPURLResponse) {
        { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }
    }

    @Test("replace mode: 3 local cards deleted, 2 remote cards pulled into local")
    func replaceDestructivePull() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Local state: 3 cards
        _ = h.cardRepo.createCard(in: h.column, title: "Local A")
        _ = h.cardRepo.createCard(in: h.column, title: "Local B")
        _ = h.cardRepo.createCard(in: h.column, title: "Local C")
        try h.persistence.viewContext.save()

        // Remote state: 1 column + 2 cards (one golden, one tagged)
        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"Remote One","status":"published","description":"desc one","description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
          {"id":"fz2","number":2,"title":"Remote Two","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":["bug"],"golden":true,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
        ]
        """
        h.mock.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.itemsDeleted == 3)
        #expect(result.itemsCreated == 2)
        #expect(result.errors.isEmpty)

        // Verify local state matches remote
        let localCards: [Card] = (h.column.cards as? Set<Card>).map { Array($0) } ?? []
        let titles = Set(localCards.compactMap(\.title))
        #expect(titles == Set(["Remote One", "Remote Two"]))

        // Verify golden flag was pulled
        let golden = localCards.first { $0.title == "Remote Two" }
        #expect(golden?.isGolden == true)

        // Verify a local Label was auto-created for the "bug" tag and attached
        #expect(golden?.sortedLabels.first?.name == "bug")
    }

    @Test("replace mode: remote column missing locally → auto-created")
    func replaceAutoCreatesLocalColumn() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Remote has a column named "In Progress" that doesn't exist locally
        let columnsJSON = """
        [{"id":"FC2","name":"In Progress","color":{"name":"Lime","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = "[]"
        h.mock.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.errors.isEmpty)

        // Verify the column exists locally now
        let localColumns: [Column] = (h.board.columns as? Set<Column>).map { Array($0) } ?? []
        let localColumnNames = Set(localColumns.compactMap(\.name))
        #expect(localColumnNames.contains("In Progress"))
    }
}

@Suite("FizzySyncEngine — first-sync mode 3 (merge)", .serialized)
@MainActor
struct FizzySyncEngineMergeTests {

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

            let prefix = "test.fizzy.merge.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.merge.mapping.\(UUID().uuidString)"
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
    }

    @Test("merge mode: no title overlap → 2 POSTs + 2 local creates, no errors")
    func mergeNoOverlap() async throws {
        let h = Harness()
        defer { h.tearDown() }

        _ = h.cardRepo.createCard(in: h.column, title: "Local A")
        _ = h.cardRepo.createCard(in: h.column, title: "Local B")
        try h.persistence.viewContext.save()

        var postCount = 0
        var nextNumber = 100

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [
                  {"id":"fzR1","number":1,"title":"Remote X","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
                  {"id":"fzR2","number":2,"title":"Remote Y","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
                ]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let n = nextNumber
                nextNumber += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(n)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let n = (p as NSString).lastPathComponent
                let body = """
                {"id":"fz-\(n)","number":\(n),"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/\(n)"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(postCount == 2, "both local cards pushed")
        #expect(result.itemsCreated == 4, "2 POSTs + 2 local creates from remote")
        #expect(result.errors.isEmpty)

        let localCards: [Card] = (h.column.cards as? Set<Card>).map { Array($0) } ?? []
        let localTitles = Set(localCards.compactMap(\.title))
        #expect(localTitles == Set(["Local A", "Local B", "Remote X", "Remote Y"]))
    }

    @Test("merge mode: title collision → FizzySyncResult.errors entry, neither side merged")
    func mergeWithTitleCollision() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let collidingLocal = h.cardRepo.createCard(in: h.column, title: "Shared title")
        _ = h.cardRepo.createCard(in: h.column, title: "Only local")
        try h.persistence.viewContext.save()

        var postCount = 0
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [
                  {"id":"fzR1","number":1,"title":"Shared title","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
                  {"id":"fzR2","number":2,"title":"Only remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
                ]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/99"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let n = (p as NSString).lastPathComponent
                let body = """
                {"id":"fz-\(n)","number":\(n),"title":"Only local","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/\(n)"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(postCount == 1, "only Only local is pushed; Shared title is skipped due to collision")
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains("Shared title") == true)

        // The colliding local card keeps its nil fizzyID — unmerged.
        h.persistence.viewContext.refresh(collidingLocal, mergeChanges: false)
        #expect(collidingLocal.fizzyID == nil)
    }
}

@Suite("FizzySyncEngine — sync() pairing precondition", .serialized)
@MainActor
struct FizzySyncEngineSyncPairingTests {

    @Test("sync() returns empty FizzySyncResult when unpaired")
    func unpairedReturnsEmpty() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let authState = FizzyAuthState(keyPrefix: "test.fizzy.sync.\(UUID().uuidString)")
        defer { authState.clear() }
        let suiteName = "test.fizzy.sync.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)

        let client = FizzyClient(
            baseURL: URL(string: "https://example.invalid")!,
            accessToken: "t",
            accountSlug: "ACCT"
        )
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )

        let result = try await engine.sync()
        #expect(result == FizzySyncResult())
    }
}

@Suite("FizzySyncEngine — steady-state pull", .serialized)
@MainActor
struct FizzySyncEngineSteadyPullTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let mapping: FizzyBoardMapping
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
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

            let prefix = "test.fizzy.steadypull.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.steadypull.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }
    }

    @Test("steady pull: 3 remote, 0 local with fizzyID → 3 local created")
    func pullRemoteOnly() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"R1","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"},
          {"id":"fz2","number":2,"title":"R2","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/2"},
          {"id":"fz3","number":3,"title":"R3","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/3"}
        ]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.itemsCreated == 3)
        #expect(result.errors.isEmpty)

        let titles = Set(((h.column.cards as? Set<Card>).map { Array($0) } ?? []).compactMap(\.title))
        #expect(titles == Set(["R1", "R2", "R3"]))
    }

    @Test("steady pull: skips remote cards already paired locally (no duplicate creates)")
    func pullSkipsAlreadyPaired() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Local card already paired with fz1
        let paired = h.cardRepo.createCard(in: h.column, title: "Existing")
        paired.fizzyID = "fz1"
        try h.persistence.viewContext.save()

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"Existing","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(result.itemsCreated == 0, "no new cards — fz1 already paired")
    }

    @Test("pull: card with three tags maps all three to labels")
    func pullMapsAllTags() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [{"id":"fzT1","number":11,"title":"Tagged","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":["bug","urgent","backend"],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/11"}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()

        let card = h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 11 }
        let names = card?.sortedLabels.compactMap(\.name)
        #expect(names == ["backend", "bug", "urgent"])
    }

    @Test("pull: case-colliding tags dedupe to a single label")
    func pullDedupesCaseCollidingTags() async throws {
        // findOrCreateLabel fetches `name ==[c]` on the same context, so
        // pending inserts within one applyRemote dedupe by construction —
        // ["Bug","bug","BUG"] must yield exactly ONE local Label.
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [{"id":"fzT3","number":13,"title":"Shouty","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":["Bug","bug","BUG"],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/13"}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()

        let card = try #require(h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 13 })
        #expect(card.sortedLabels.count == 1)

        let request: NSFetchRequest<Label> = Label.fetchRequest()
        request.predicate = NSPredicate(format: "name ==[c] %@", "bug")
        let matching = try h.persistence.viewContext.fetch(request)
        #expect(matching.count == 1)
    }

    @Test("pull: tags removed remotely clears local labels")
    func pullClearsRemovedTags() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Seed a paired local card that already has two labels. Timestamps
        // force the remote-newer LWW branch (remote last_active_at is newer
        // than fizzyUpdatedAt; local untouched since last sync).
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Was tagged")
        card.fizzyID = "fzT2"
        card.fizzyNumber = 12
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline
        let repo = LabelRepository(context: h.persistence.viewContext)
        card.addToLabels(repo.createLabel(name: "bug", colorHex: "#FF0000"))
        card.addToLabels(repo.createLabel(name: "urgent", colorHex: "#00FF00"))
        try h.persistence.viewContext.save()

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [{"id":"fzT2","number":12,"title":"Was tagged","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-11T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/12"}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()
        #expect(card.sortedLabels.isEmpty)
    }

    @Test("pull: card assignees land in the persisted blob")
    func pullMapsAssignees() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [{"id":"fzA1","number":21,"title":"Assigned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/21","assignees":[{"id":"u1","name":"Ada Lovelace","role":"member","active":true,"email_address":"ada@example.com","created_at":"2025-12-05T19:36:35.401Z","url":"https://fizzy.bluefenix.net/ACCT/users/u1","avatar_url":"https://fizzy.bluefenix.net/ACCT/users/u1/avatar"}],"has_more_assignees":false}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()

        let card = h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 21 }
        #expect(card?.assignees == [CardAssignee(id: "u1", name: "Ada Lovelace")])
    }

    @Test("pull: empty assignees array clears the blob; absent key preserves it")
    func pullClearsOrPreservesAssignees() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Seed a paired local card with an assignee already in the blob.
        // Timestamps force the remote-newer LWW branch (remote last_active_at
        // newer than fizzyUpdatedAt; local untouched since last sync).
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Assigned once")
        card.fizzyID = "fzA2"
        card.fizzyNumber = 22
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline
        card.assignees = [CardAssignee(id: "u9", name: "Stale Person")]
        try h.persistence.viewContext.save()

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """

        // Round 1: remote carries an EMPTY assignees array → clear the blob.
        let round1CardsJSON = """
        [{"id":"fzA2","number":22,"title":"Assigned once","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-11T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/22","assignees":[],"has_more_assignees":false}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (round1CardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()
        #expect(card.assignees == [], "empty remote array clears the blob")

        // Re-seed the blob so round 2 genuinely distinguishes "left alone"
        // from "cleared". Touching only assigneesData keeps modifiedAt ==
        // fizzyUpdatedAt, so the pull branch still runs.
        let seeded = [CardAssignee(id: "u1", name: "Ada Lovelace")]
        card.assignees = seeded
        try h.persistence.viewContext.save()

        // Round 2: remote payload has NO assignees key at all (single-card-doc
        // shape) and a newer last_active_at → blob must be PRESERVED.
        let round2CardsJSON = """
        [{"id":"fzA2","number":22,"title":"Assigned once","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-12T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/22"}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (round2CardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()
        // fizzyUpdatedAt lives in the pairing store now (issue #21 A′) —
        // the attribute is a hint that only heals fizzyID/number.
        let cardUUID = try #require(card.id)
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyUpdatedAt
                    == ISO8601DateFormatter().date(from: "2026-06-12T00:00:00Z"),
                "round 2 pull branch ran")
        #expect(card.assignees == seeded, "absent assignees key leaves the blob alone")
    }
}

@Suite("FizzySyncEngine — steady-state push", .serialized)
@MainActor
struct FizzySyncEngineSteadyPushTests {

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

            let prefix = "test.fizzy.steadypush.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.steadypush.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }
    }

    @Test("steady push: 1 local with nil fizzyID + 0 remote → 1 POST, fizzyID stored")
    func pushLocalOnly() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Local")
        try h.persistence.viewContext.save()

        var postCount = 0
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/55"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/55"):
                let body = """
                {"id":"fz-55","number":55,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/55"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(postCount == 1)
        #expect(result.itemsCreated == 1)
        h.persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "fz-55")
    }
}

@Suite("FizzySyncEngine — LWW conflict resolution", .serialized)
@MainActor
struct FizzySyncEngineLWWTests {

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

            let prefix = "test.fizzy.lww.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.lww.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }
    }

    @Test("LWW: remote newer than local fizzyUpdatedAt → local updated from remote")
    func remoteNewerWins() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let newerRemote = Date(timeIntervalSince1970: 1_001_000)

        let card = h.cardRepo.createCard(in: h.column, title: "Old title")
        card.fizzyID = "fz1"
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline  // local hasn't changed since last sync
        try h.persistence.viewContext.save()

        let iso = ISO8601DateFormatter().string(from: newerRemote)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"New title","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(result.itemsUpdated == 1)
        h.persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.title == "New title")
    }

    @Test("LWW: local modifiedAt newer than fizzyUpdatedAt → PUT issued")
    func localNewerPushes() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let newerLocal = Date(timeIntervalSince1970: 1_001_500)

        let card = h.cardRepo.createCard(in: h.column, title: "Local edit")
        card.fizzyID = "fz1"
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = newerLocal
        try h.persistence.viewContext.save()

        var putCount = 0
        let isoBaseline = ISO8601DateFormatter().string(from: baseline)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"Stale remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(isoBaseline)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("PUT", let p?) where p.contains("/cards/"):
                putCount += 1
                let body = """
                {"id":"fz1","number":1,"title":"Local edit","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(isoBaseline)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(putCount == 1)
        #expect(result.itemsUpdated == 1)
    }
}

@Suite("FizzySyncEngine — soft-delete on missing remote", .serialized)
@MainActor
struct FizzySyncEngineSoftDeleteTests {

    @Test("paired local card not in remote response → deleted locally")
    func softDeletesMissingRemote() async throws {
        let mock = MockHTTPState()
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.delete.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.delete.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        // Paired local card; remote will return empty list. The number hint
        // matters: deletion is only confirmed via GET /cards/:number → 404
        // (per-column lists exclude closed cards, so absence alone no longer
        // deletes — task #48).
        let card = cardRepo.createCard(in: column, title: "Doomed")
        card.fizzyID = "fz-doomed"
        card.fizzyNumber = 9
        try persistence.viewContext.save()
        let cardObjectID = card.objectID

        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )

        mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"C","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.contains("/cards/"):
                // Deletion confirmation: the card is gone on the server.
                return (Data(), .response(for: req, status: 404))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )
        let result = try await engine.sync()

        #expect(result.itemsDeleted == 1)
        // The card should be deleted from the context.
        let stillExists = (try? persistence.viewContext.existingObject(with: cardObjectID)) as? Card
        #expect(stillExists?.isDeleted == true || stillExists == nil)
    }
}

@Suite("FizzySyncEngine — crash-after-POST recovery", .serialized)
@MainActor
struct FizzySyncEngineCrashRecoveryTests {

    @Test("local nil-fizzyID + remote matching title within 60s → claim orphan, no duplicate POST")
    func claimsOrphan() async throws {
        let mock = MockHTTPState()
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.crash.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.crash.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = cardRepo.createCard(in: column, title: "Orphan-prone")
        card.createdAt = baseline
        try persistence.viewContext.save()

        var postCount = 0
        let withinWindow = baseline.addingTimeInterval(30)  // 30s after local create
        let iso = ISO8601DateFormatter().string(from: withinWindow)
        mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"C","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz-orphan","number":1,"title":"Orphan-prone","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"\(iso)","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                postCount += 1
                return (Data(), .response(for: req, status: 201, headers: ["Location": "https://x/999"]))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )

        let result = try await engine.sync()

        #expect(postCount == 0, "should NOT POST — orphan claimed")
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "fz-orphan", "local claimed the orphan")
        #expect(result.errors.isEmpty)
    }

    @Test("orphan claim does not also pull-create a duplicate local card")
    func orphanClaimNoDuplicatePull() async throws {
        let mock = MockHTTPState()
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.crashdup.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.crashdup.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = cardRepo.createCard(in: column, title: "Orphan-prone")
        card.createdAt = baseline
        try persistence.viewContext.save()

        let withinWindow = baseline.addingTimeInterval(30)
        let iso = ISO8601DateFormatter().string(from: withinWindow)
        mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"C","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz-orphan","number":1,"title":"Orphan-prone","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"\(iso)","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                Issue.record("orphan claim should suppress POST")
                return (Data(), .response(for: req, status: 201, headers: ["Location": "https://x/999"]))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )

        _ = try await engine.sync()

        // Across the entire board there should be exactly ONE local card with
        // fizzyID == "fz-orphan" — the original claimer. The pull loop must
        // not have also created a duplicate.
        let request: NSFetchRequest<Card> = Card.fetchRequest()
        request.predicate = NSPredicate(format: "fizzyID == %@", "fz-orphan")
        let matches = try persistence.viewContext.fetch(request)
        #expect(matches.count == 1, "expected single claimer, got \(matches.count)")
    }
}

@Suite("FizzySyncEngine — idempotence", .serialized)
@MainActor
struct FizzySyncEngineIdempotenceTests {

    @Test("running sync() twice in a row produces zero changes on second run")
    func doubleSyncIsNoop() async throws {
        let mock = MockHTTPState()
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        _ = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.idemp.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.idemp.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        let stableISO = "2026-05-25T00:00:00Z"
        mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"C","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"R","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(stableISO)","created_at":"\(stableISO)","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )

        let first = try await engine.sync()
        let second = try await engine.sync()

        #expect(first.itemsCreated == 1)
        #expect(second.itemsCreated == 0)
        #expect(second.itemsUpdated == 0)
        #expect(second.itemsDeleted == 0)
        #expect(second.errors.isEmpty)
    }
}

@Suite("FizzySyncEngine — 401 handling", .serialized)
@MainActor
struct FizzySyncEngine401Tests {

    @Test("401 from remote clears authState; engine surfaces error")
    func unauthorizedClearsAuth() async throws {
        let mock = MockHTTPState()
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        _ = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.401.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("revoked-token")
        authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.401.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        mock.handler = { req in
            (Data(), .response(for: req, status: 401))
        }

        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }
        let session = mock.makeSession()
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "revoked-token", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext, pairingStore: pairingStore
        )

        // Pre-condition
        #expect(authState.accessToken == "revoked-token")

        do {
            _ = try await engine.sync()
            Issue.record("expected sync() to throw on 401")
        } catch let error as FizzyError {
            #expect(error == .unauthorized)
        }

        // Post-condition: authState cleared
        #expect(authState.accessToken == nil)
    }
}

@Suite("FizzySyncEngine — card-number addressing + reentrancy", .serialized)
@MainActor
struct FizzySyncEngineNumberReentrancyTests {

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

            let prefix = "test.fizzy.numre.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.numre.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }
    }

    private static func cardJSON(id: String, number: Int, title: String, iso: String) -> String {
        """
        {"id":"\(id)","number":\(number),"title":"\(title)","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"2026-01-01T00:00:00Z","url":"https://x/\(number)"}
        """
    }

    @Test("LWW push PUTs to /cards/<number> (backfilled from list), never the ULID id")
    func putUsesCardNumber() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Local edit")
        card.fizzyID = "03f5vaeq985jlvwv3arl4srq2"   // ULID, not a number
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = Date(timeIntervalSince1970: 1_001_500)
        try h.persistence.viewContext.save()

        var putPaths: [String] = []
        let iso = ISO8601DateFormatter().string(from: baseline)
        let listJSON = "[\(Self.cardJSON(id: "03f5vaeq985jlvwv3arl4srq2", number: 7, title: "Stale", iso: iso))]"
        let showJSON = Self.cardJSON(id: "03f5vaeq985jlvwv3arl4srq2", number: 7, title: "Local edit", iso: iso)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (listJSON.data(using: .utf8)!, .ok(for: req))
            case ("PUT", let p?):
                putPaths.append(p)
                return (showJSON.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.sync()
        #expect(putPaths == ["/ACCT/cards/7"])
        #expect(card.fizzyNumber == 7)
    }

    @Test("steady push stores created card's number for future PUTs")
    func postStoresNumber() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Fresh local")
        try h.persistence.viewContext.save()

        let iso = "2026-06-01T00:00:00Z"
        let created = Self.cardJSON(id: "fzNEW", number: 12, title: "Fresh local", iso: iso)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.contains("/cards/"):
                // Location-follow after POST
                return (created.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/12"]
                )!
                return (Data(), response)
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        _ = try await h.engine.sync()
        #expect(card.fizzyID == "fzNEW")
        #expect(card.fizzyNumber == 12)
    }

    @Test("double sync with a pushed card: second sync issues zero POSTs")
    func sequentialDoubleSyncDoesNotDuplicate() async throws {
        let h = Harness()
        defer { h.tearDown() }

        _ = h.cardRepo.createCard(in: h.column, title: "Once only")
        try h.persistence.viewContext.save()

        let iso = "2026-06-01T00:00:00Z"
        var postCount = 0
        var remoteList: [String] = []   // stateful: POSTed cards join the list
        let created = Self.cardJSON(id: "fzX", number: 3, title: "Once only", iso: iso)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[\(remoteList.joined(separator: ","))]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.contains("/cards/"):
                // Location-follow after POST
                return (created.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                postCount += 1
                remoteList.append(created)
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/3"]
                )!
                return (Data(), response)
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let first = try await h.engine.sync()
        let second = try await h.engine.sync()

        #expect(postCount == 1)
        #expect(first.itemsCreated == 1)
        #expect(second.itemsCreated == 0)
        #expect(second.errors.isEmpty)
    }

    @Test("overlapping sync() calls: in-flight guard prevents duplicate POSTs")
    func overlappingSyncsDoNotDuplicate() async throws {
        let h = Harness()
        defer { h.tearDown() }

        _ = h.cardRepo.createCard(in: h.column, title: "Once only")
        try h.persistence.viewContext.save()

        let iso = "2026-06-01T00:00:00Z"
        var postCount = 0
        let created = Self.cardJSON(id: "fzY", number: 4, title: "Once only", iso: iso)
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.contains("/cards/"):
                // Location-follow after POST
                return (created.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/4"]
                )!
                return (Data(), response)
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        async let a = h.engine.sync()
        async let b = h.engine.sync()
        let (ra, rb) = try await (a, b)

        #expect(postCount == 1)
        #expect(ra.itemsCreated + rb.itemsCreated == 1)
    }

    @Test("card pull follows Link rel=\"next\" so multi-page boards sync fully")
    func cardPullFollowsPagination() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let iso = "2026-06-01T00:00:00Z"
        let page1 = "[\(Self.cardJSON(id: "fzPG1", number: 21, title: "Page one card", iso: iso))]"
        let page2 = "[\(Self.cardJSON(id: "fzPG2", number: 22, title: "Page two card", iso: iso))]"
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                if req.url?.query?.contains("page=2") == true {
                    return (page2.data(using: .utf8)!, .ok(for: req))
                }
                let headers = ["Link": "<https://fizzy.bluefenix.net/ACCT/cards?board_ids%5B%5D=FB1&page=2>; rel=\"next\""]
                return (page1.data(using: .utf8)!, .ok(for: req, headers: headers))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(result.itemsCreated == 2)

        let fetch = Card.fetchRequest()
        let cards = try h.persistence.viewContext.fetch(fetch)
        #expect(Set(cards.compactMap(\.fizzyID)) == ["fzPG1", "fzPG2"])
    }
}

@Suite("FizzySyncEngine — local card delete propagation", .serialized)
@MainActor
struct FizzySyncEngineDeletePropagationTests {

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

            let prefix = "test.fizzy.delprop.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.delprop.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }

        func cardTombstones() throws -> [CardTombstone] {
            let request: NSFetchRequest<CardTombstone> = CardTombstone.fetchRequest()
            return try persistence.viewContext.fetch(request)
        }
    }

    @Test("deleted paired card → tombstone → DELETE /cards/<number> before any pull, then purged")
    func deletePropagatesAndPurgesTombstone() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Doomed")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        try h.persistence.viewContext.save()

        // Local delete via the repository writes the tombstone.
        h.cardRepo.deleteCard(card)
        #expect(try h.cardTombstones().count == 1)

        var requestLog: [String] = []
        h.mock.handler = { req in
            requestLog.append("\(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.hasSuffix("/cards/7"):
                return (Data(), .response(for: req, status: 204))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(requestLog.first == "DELETE /ACCT/cards/7", "deletions push BEFORE pulls")
        #expect(requestLog.filter { $0.hasPrefix("DELETE") } == ["DELETE /ACCT/cards/7"])
        #expect(result.itemsDeleted == 1)
        #expect(result.errors.isEmpty)
        #expect(try h.cardTombstones().isEmpty, "tombstone purged after successful DELETE")
    }

    @Test("DELETE answering 404 → tombstone purged, no error recorded")
    func delete404PurgesTombstone() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let tombstone = CardTombstone(context: h.persistence.viewContext)
        tombstone.fizzyNumber = 9
        tombstone.deletedAt = Date()
        try h.persistence.viewContext.save()

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.hasSuffix("/cards/9"):
                return (Data(), .response(for: req, status: 404))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty, "404 means already deleted remotely — not an error")
        #expect(try h.cardTombstones().isEmpty, "tombstone purged on 404")
    }

    @Test("DELETE answering 500 → tombstone retained, error recorded, sync continues")
    func delete500RetainsTombstone() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let tombstone = CardTombstone(context: h.persistence.viewContext)
        tombstone.fizzyNumber = 9
        tombstone.deletedAt = Date()
        try h.persistence.viewContext.save()

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.hasSuffix("/cards/9"):
                return (Data(), .response(for: req, status: 500))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.count == 1)
        #expect(result.itemsDeleted == 0)
        #expect(try h.cardTombstones().count == 1, "tombstone retained for retry next sync")
    }

    @Test("live tombstone blocks pull resurrection of the same card number")
    func tombstoneBlocksResurrection() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let tombstone = CardTombstone(context: h.persistence.viewContext)
        tombstone.fizzyNumber = 7
        tombstone.deletedAt = Date()
        try h.persistence.viewContext.save()

        // DELETE fails (500) so the tombstone stays live; the remote list
        // still contains card number 7 — it must NOT be re-created locally.
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.hasSuffix("/cards/7"):
                return (Data(), .response(for: req, status: 500))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz7","number":7,"title":"Zombie","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-01T00:00:00Z","created_at":"2026-06-01T00:00:00Z","url":"https://x/7"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.itemsCreated == 0, "tombstoned card must not resurrect")
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        #expect(cards.isEmpty)
        #expect(try h.cardTombstones().count == 1)
    }

    @Test("tombstone older than 30 days → purged without issuing a DELETE")
    func staleTombstonePurgedWithoutDelete() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let tombstone = CardTombstone(context: h.persistence.viewContext)
        tombstone.fizzyNumber = 9
        tombstone.deletedAt = Date().addingTimeInterval(-31 * 24 * 3600)
        try h.persistence.viewContext.save()

        var deleteCount = 0
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", _):
                deleteCount += 1
                return (Data(), .response(for: req, status: 204))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (#"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(deleteCount == 0, "stale tombstones are abandoned, not retried")
        #expect(result.errors.isEmpty)
        #expect(try h.cardTombstones().isEmpty, "30-day safety cap purges the tombstone")
    }
}

@Suite("FizzySyncEngine — column push (create/rename/delete)", .serialized)
@MainActor
struct FizzySyncEngineColumnPushTests {

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

            let prefix = "test.fizzy.colpush.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.colpush.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }

        func columnTombstones() throws -> [ColumnTombstone] {
            let request: NSFetchRequest<ColumnTombstone> = ColumnTombstone.fetchRequest()
            return try persistence.viewContext.fetch(request)
        }
    }

    private static func columnJSON(id: String, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","color":{"name":"Slate","value":"var(--color-card-4)"},"created_at":"2026-06-01T00:00:00Z"}
        """
    }

    @Test("local column without fizzyColumnID → POST /boards/:id/columns, returned ID claimed")
    func createPushesPostAndClaimsID() async throws {
        let h = Harness()
        defer { h.tearDown() }

        var postPaths: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/columns"):
                postPaths.append(p)
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/boards/FB1/columns/FCNEW"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/columns/FCNEW"):
                return (Self.columnJSON(id: "FCNEW", name: "Triage").data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(postPaths == ["/ACCT/boards/FB1/columns"])
        #expect(result.errors.isEmpty)
        h.persistence.viewContext.refresh(h.column, mergeChanges: false)
        #expect(h.column.fizzyColumnID == "FCNEW")
    }

    @Test("backfill: local column matching a remote name claims the remote ID, no POST")
    func backfillClaimsExistingRemoteID() async throws {
        let h = Harness()
        defer { h.tearDown() }

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[\(Self.columnJSON(id: "FC1", name: "Triage"))]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                Issue.record("name-matched column must not be re-POSTed")
                return (Data(), .response(for: req, status: 500))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        h.persistence.viewContext.refresh(h.column, mergeChanges: false)
        #expect(h.column.fizzyColumnID == "FC1")
    }

    @Test("locally renamed paired column → PUT /boards/:id/columns/:column_id")
    func renamePushesPut() async throws {
        let h = Harness()
        defer { h.tearDown() }

        h.column.fizzyColumnID = "FC1"
        h.column.name = "Doing"
        h.column.modifiedAt = Date()
        try h.persistence.viewContext.save()

        var putPaths: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[\(Self.columnJSON(id: "FC1", name: "Old name"))]".data(using: .utf8)!, .ok(for: req))
            case ("PUT", let p?) where p.contains("/columns/"):
                putPaths.append(p)
                return (Self.columnJSON(id: "FC1", name: "Doing").data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(putPaths == ["/ACCT/boards/FB1/columns/FC1"])
        #expect(result.errors.isEmpty)
        #expect(h.column.name == "Doing", "local rename wins")

        // The ID-paired remote column must not be duplicated locally under
        // its stale remote name.
        let columns = (h.board.columns as? Set<Column>) ?? []
        #expect(columns.count == 1)
    }

    @Test("deleted paired column → tombstone → DELETE /boards/:id/columns/:column_id, tombstone purged")
    func columnDeletePropagates() async throws {
        let h = Harness()
        defer { h.tearDown() }

        h.column.fizzyColumnID = "FC1"
        try h.persistence.viewContext.save()
        h.boardRepo.deleteColumn(h.column)
        #expect(try h.columnTombstones().count == 1)

        var deletePaths: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.contains("/columns/"):
                deletePaths.append(p)
                return (Data(), .response(for: req, status: 204))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(deletePaths == ["/ACCT/boards/FB1/columns/FC1"])
        #expect(result.itemsDeleted == 1)
        #expect(result.errors.isEmpty)
        #expect(try h.columnTombstones().isEmpty, "tombstone purged after successful DELETE")
    }

    @Test("live column tombstone blocks pull resurrection of the remote column")
    func columnTombstoneBlocksResurrection() async throws {
        let h = Harness()
        defer { h.tearDown() }

        h.column.fizzyColumnID = "FC1"
        try h.persistence.viewContext.save()
        h.boardRepo.deleteColumn(h.column)

        // DELETE fails (500) so the tombstone stays live; the remote list
        // still contains FC1 — it must NOT be re-created locally.
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("DELETE", let p?) where p.contains("/columns/"):
                return (Data(), .response(for: req, status: 500))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[\(Self.columnJSON(id: "FC1", name: "Triage"))]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.count == 1)
        let columns = (h.board.columns as? Set<Column>) ?? []
        #expect(columns.isEmpty, "tombstoned column must not resurrect")
        #expect(try h.columnTombstones().count == 1, "tombstone retained for retry")
    }
}

// MARK: - Pin reconciliation (issue #19 wave 3)

private final class FixtureLocatorPins {}

@Suite("FizzySyncEngine — pin reconciliation (issue #19 wave 3)", .serialized)
@MainActor
struct FizzySyncEnginePinReconciliationTests {

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

            let prefix = "test.fizzy.pins.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.pins.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let session = mock.makeSession()
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
        }
    }

    /// Loads a wire-shape fixture verbatim (mirrors FizzyClientBoardsTests).
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorPins.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        // Fallback: resolve via #file path (works when resources aren't bundled)
        let testFile = #file
        let testURL = URL(fileURLWithPath: testFile)
        let testBundleDir = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixturePath = testBundleDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    @Test("sync: pins from GET /my/pins land on isPinned (fixture verbatim)")
    func syncReconcilesPinsFromMyPins() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        // Two cards: the first's id matches pins_doc.json's first pin; the second doesn't.
        let cardsJSON = """
        [{"id":"03f5vaeq985jlvwv3arl4srq2","number":31,"title":"Pinned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/31"},{"id":"fzB2","number":32,"title":"Unpinned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/32"}]
        """
        let pinsData = try loadFixture("pins_doc")
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (pinsData, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()

        let cards = h.cardRepo.fetchAllCards(in: h.board)
        #expect(cards.first { $0.fizzyNumber == 31 }?.isPinned == true)
        #expect(cards.first { $0.fizzyNumber == 32 }?.isPinned == false)
    }

    @Test("sync: card absent from GET /my/pins is unpinned (remote-authoritative)")
    func syncClearsUnpinnedCards() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        // Identical card content both rounds — pin reconciliation is
        // independent of the LWW card branches, so round 2's pull is a no-op
        // for content and only the pin state moves.
        let cardsJSON = """
        [{"id":"fzP1","number":41,"title":"Pinned once","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/41"}]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        // Round 1: card pulled and paired.
        _ = try await h.engine.sync()
        let card = try #require(h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 41 })

        // Pin locally, then sync again with an empty remote pin set.
        // Touching only isPinned keeps modifiedAt == fizzyUpdatedAt, so the
        // LWW branches stay quiet and only pin reconciliation acts.
        card.isPinned = true
        try h.persistence.viewContext.save()

        _ = try await h.engine.sync()

        #expect(card.isPinned == false, "remote pin set is authoritative — absent means unpinned")
    }

    @Test("sync: failed GET /my/pins leaves pin state alone and does not fail the sync")
    func pinsFetchFailureLeavesPinStateAlone() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [{"id":"fzP2","number":42,"title":"Sticky pin","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/42"}]
        """
        // Round 1: remote pin set contains the card → isPinned becomes true.
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()
        let card = try #require(h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 42 })
        #expect(card.isPinned == true, "round 1 seeded the pin")

        // Round 2: the pins fetch fails (422). Best-effort — the sync must
        // not throw and the pre-sync pin state must survive untouched.
        // No Issue.record for the pins arm: the failure is the point.
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data(), .response(for: req, status: 422))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 422))
            }
        }

        _ = try await h.engine.sync()

        #expect(card.isPinned == true, "failed pins fetch leaves pin state alone")
    }
}
