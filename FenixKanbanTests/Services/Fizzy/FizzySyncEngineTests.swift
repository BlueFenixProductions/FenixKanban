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
        let engine = FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext
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
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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
        MockURLProtocol.handler = { req in
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
        MockURLProtocol.handler = { req in
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

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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
        MockURLProtocol.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

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
        #expect(golden?.label?.name == "bug")
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
        MockURLProtocol.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

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
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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

        MockURLProtocol.handler = { req in
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
        MockURLProtocol.handler = { req in
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
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        let result = try await engine.sync()
        #expect(result == FizzySyncResult())
    }
}

@Suite("FizzySyncEngine — steady-state pull", .serialized)
@MainActor
struct FizzySyncEngineSteadyPullTests {

    private struct Harness {
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

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
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

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
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
}

@Suite("FizzySyncEngine — steady-state push", .serialized)
@MainActor
struct FizzySyncEngineSteadyPushTests {

    private struct Harness {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("steady push: 1 local with nil fizzyID + 0 remote → 1 POST, fizzyID stored")
    func pushLocalOnly() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Local")
        try h.persistence.viewContext.save()

        var postCount = 0
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
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
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
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
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
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
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
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
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
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

        // Paired local card; remote will return empty list.
        let card = cardRepo.createCard(in: column, title: "Doomed")
        card.fizzyID = "fz-doomed"
        try persistence.viewContext.save()
        let cardObjectID = card.objectID

        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
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
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
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

        MockURLProtocol.reset()
        var postCount = 0
        let withinWindow = baseline.addingTimeInterval(30)  // 30s after local create
        let iso = ISO8601DateFormatter().string(from: withinWindow)
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        let result = try await engine.sync()

        #expect(postCount == 0, "should NOT POST — orphan claimed")
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "fz-orphan", "local claimed the orphan")
        #expect(result.errors.isEmpty)
    }
}
