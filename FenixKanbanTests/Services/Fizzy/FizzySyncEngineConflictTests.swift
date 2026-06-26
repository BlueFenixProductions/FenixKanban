import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - File-scope fixtures

private let conflictColumnsJSON = """
[
  {"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}
]
"""

private func conflictCardJSON(
    id: String, number: Int, title: String,
    description: String? = nil,
    columnID: String = "FC1", columnName: String = "Triage",
    lastActiveAt: String = "2026-05-25T00:00:10Z",
    tags: [String] = [], assigneeIDs: [String] = []
) -> String {
    let descJSON = description.map { "\"\($0)\"" } ?? "null"
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
     "description":\(descJSON),"description_html":null,"image_url":null,
     "has_attachments":false,"tags":[\(tagsJSON)],"closed":false,"postponed":false,
     "golden":false,"last_active_at":"\(lastActiveAt)",
     "created_at":"2026-05-25T00:00:00Z",
     "url":"https://fizzy.bluefenix.net/ACCT/cards/\(number)",
     "column":{"id":"\(columnID)","name":"\(columnName)","color":"var(--color-card-4)","created_at":"2026-05-25T00:00:00Z"},
     "assignees":[\(assigneesJSON)]}
    """
}

/// Minimal request recorder for conflict tests.
private final class ConflictBoard: @unchecked Sendable {
    let remoteCardsJSON: String
    private let lock = NSLock()
    private var _mutations: [(method: String, path: String, body: String)] = []
    var mutations: [(method: String, path: String, body: String)] {
        lock.lock(); defer { lock.unlock() }; return _mutations
    }
    var shouldReturn500ForPUT = false

    init(remoteCardsJSON: String) { self.remoteCardsJSON = remoteCardsJSON }

    func handler(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "?"
        switch method {
        case "GET" where path.hasSuffix("/my/pins"):
            return (Data("[]".utf8), .ok(for: req))
        case "GET" where path.hasSuffix("/columns"):
            return (Data(conflictColumnsJSON.utf8), .ok(for: req))
        case "GET" where path.contains("/columns/") && path.hasSuffix("/cards"):
            return (Data(remoteCardsJSON.utf8), .ok(for: req))
        case "PUT" where path.contains("/cards/"):
            record(method, path, req)
            if shouldReturn500ForPUT {
                return (Data(), .response(for: req, status: 500))
            }
            // Echo back the local card (whatever was PUT)
            let echo = conflictCardJSON(id: "fz9", number: 9, title: "Local Title",
                                        lastActiveAt: "2026-06-12T06:00:00Z")
            return (Data(echo.utf8), .ok(for: req))
        case "POST" where path.contains("/taggings") || path.contains("/triage") || path.contains("/assignments"):
            record(method, path, req)
            return (Data(), .response(for: req, status: 204))
        default:
            Issue.record("unexpected request: \(method) \(path)")
            return (Data(), .response(for: req, status: 500))
        }
    }

    private func record(_ method: String, _ path: String, _ req: URLRequest) {
        let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        lock.lock(); defer { lock.unlock() }
        _mutations.append((method, path, body))
    }
}

// MARK: - Harness

@MainActor
private struct ConflictHarness {
    let mock = MockHTTPState()
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let triage: Column
    let engine: FizzySyncEngine
    let authState: FizzyAuthState
    let boardPairingStore: FizzyBoardPairingStore
    // Kept for FizzySyncProvider calls in Task 4 tests (not yet migrated)
    let mappingDefaults: UserDefaults
    let suiteName: String
    let pairingStore: FizzyCardPairingStore
    let conflictStore: FizzyConflictStore

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)

        let uniqueID = UUID().uuidString
        pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(uniqueID).json")
        )
        conflictStore = FizzyConflictStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-conflicts-\(uniqueID).json")
        )
        cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        board = boardRepo.createBoard(name: "Roadmap")
        triage = boardRepo.createColumn(in: board, name: "Triage")
        triage.fizzyColumnID = "FC1"
        try! persistence.viewContext.save()

        let prefix = "test.fizzy.conflict.\(uniqueID)"
        authState = FizzyAuthState(keyPrefix: prefix)
        authState.setAccessToken("t")
        authState.setAccountSlug("ACCT")

        // Board pairing store for the engine (Task 3 refactor)
        boardPairingStore = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-board-pairings-\(uniqueID).json")
        )
        boardPairingStore.upsert(FizzyBoardPairing(localBoardID: board.id!, fizzyBoardID: "FB1"))

        // Kept for FizzySyncProvider tests (Task 4 will migrate these too)
        suiteName = "test.fizzy.conflict.mapping.\(uniqueID)"
        mappingDefaults = UserDefaults(suiteName: suiteName)!
        let legacyMapping = FizzyBoardMapping(defaults: mappingDefaults)
        legacyMapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

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
            pairingStore: pairingStore,
            conflictStore: conflictStore
        )
    }

    func tearDown() {
        authState.clear()
        mappingDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: boardPairingStore.fileURL)
        try? FileManager.default.removeItem(at: pairingStore.fileURL)
        try? FileManager.default.removeItem(at: conflictStore.fileURL)
    }

    /// t0 = epoch for predictable timestamps
    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Creates a locally-edited card paired at t0 with t0+120 local modifiedAt.
    func seedConflictCard(
        localTitle: String = "Local Title",
        localDescription: String? = nil
    ) -> Card {
        let card = cardRepo.createCard(in: triage, title: localTitle)
        card.cardDescription = localDescription
        try! persistence.viewContext.save()
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz9", fizzyNumber: 9,
                             fizzyUpdatedAt: Self.t0),
            for: card.id!
        )
        card.modifiedAt = Self.t0.addingTimeInterval(120) // local edit after watermark
        return card
    }
}

// MARK: - Suite

/// Task #70 — conflict surfacing + offline awareness.
@Suite("FizzySyncEngine — conflicts (task #70)", .serialized)
@MainActor
struct FizzySyncEngineConflictTests {

    // MARK: Test 1: conflict detected when both sides moved title

    @Test("conflict detected when both sides moved title since watermark")
    func conflictDetected_whenBothSidesMovedTitle() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Local Title")
        // Remote changed title at t0+60 (after watermark, before local edit)
        let remoteLastActiveAt = ConflictHarness.t0.addingTimeInterval(60)
        let remoteCardJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Remote Title",
            lastActiveAt: ISO8601DateFormatter().string(from: remoteLastActiveAt)
        )
        let board = ConflictBoard(remoteCardsJSON: "[\(remoteCardJSON)]")
        h.mock.handler = { try board.handler($0) }

        // Diagnostic: verify harness preconditions
        #expect(h.authState.isConfigured, "authState must be configured before sync")
        #expect(h.pairingStore.pairing(for: card.id!) != nil, "pairing must be stored before sync")
        let pairing = h.pairingStore.pairing(for: card.id!)!
        #expect(pairing.fizzyID == "fz9", "fizzyID must be fz9")
        #expect(card.modifiedAt == ConflictHarness.t0.addingTimeInterval(120),
                "card.modifiedAt must be t0+120 before sync")
        #expect((card.modifiedAt ?? .distantPast) > pairing.fizzyUpdatedAt,
                "localModified must be > watermark")

        let result = try await h.engine.sync(localBoardID: h.board.id!)

        // Also check errors to understand what happened
        if !result.errors.isEmpty {
            Issue.record("sync returned errors: \(result.errors)")
        }

        // conflict emitted
        #expect(result.conflicts.count == 1, "expected 1 conflict, got \(result.conflicts.count)")
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.id == card.id!, "conflict ID must be local card UUID")
        #expect(conflict.remoteTitle == "Remote Title")
        #expect(conflict.localTitle == "Local Title")
        // conflict stored durably
        #expect(h.conflictStore.record(for: card.id!) != nil,
                "conflict must be persisted in conflictStore")
    }

    // MARK: Test 2: no conflict when only local moved

    @Test("no conflict when only local moved (remote at watermark)")
    func noConflict_whenOnlyLocalMoved() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        _ = h.seedConflictCard(localTitle: "Local Title")
        // Remote last_active_at == watermark (t0) → only local moved
        let remoteCardJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Local Title",
            lastActiveAt: ISO8601DateFormatter().string(from: ConflictHarness.t0)
        )
        let board = ConflictBoard(remoteCardsJSON: "[\(remoteCardJSON)]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)

        #expect(result.conflicts.isEmpty, "no conflict expected when only local moved")
        // PUT must still fire (local newer branch)
        #expect(board.mutations.contains { $0.method == "PUT" },
                "PUT must still fire on the local-newer branch")
    }

    // MARK: Test 3: no conflict when only tags/assignees differ

    @Test("no conflict when only tags and assignees differ (commutative fields)")
    func noConflict_whenOnlyTagsAndAssigneesDiffer() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Same Title")
        // Add a local label
        let labelRepo = LabelRepository(context: h.persistence.viewContext)
        let alpha = labelRepo.createLabel(name: "alpha", colorHex: "#808080")
        card.labels = NSSet(array: [alpha])
        card.assignees = [CardAssignee(id: "u1", name: "User 1")]

        // Remote: same title/desc, different tags, different assignees
        // Remote last_active_at is t0+60 (both sides "moved") — but only commutative
        let remoteLastActiveAt = ConflictHarness.t0.addingTimeInterval(60)
        let remoteCardJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Same Title",
            lastActiveAt: ISO8601DateFormatter().string(from: remoteLastActiveAt),
            tags: ["beta"], assigneeIDs: ["u2"]
        )
        let board = ConflictBoard(remoteCardsJSON: "[\(remoteCardJSON)]")
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)

        #expect(result.conflicts.isEmpty, "no conflict for commutative field differences only")
        // Toggle diffs still fire
        let toggles = board.mutations.filter {
            $0.path.contains("/taggings") || $0.path.contains("/assignments")
        }
        #expect(!toggles.isEmpty, "toggle diffs must still fire for commutative fields")
    }

    // MARK: Test 4: resolveKeepMine

    @Test("resolveKeepMine pushes local title, advances watermark, clears conflict record")
    func keepMine_pushesLocalAndClearsConflict() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Local Title")
        let cardID = card.id!

        // Seed a conflict record manually
        let remoteAt = ConflictHarness.t0.addingTimeInterval(60)
        let record = ConflictRecord(
            id: cardID,
            fizzyNumber: 9,
            localTitle: "Local Title",
            localDescription: nil,
            remoteTitle: "Remote Title",
            remoteDescription: nil,
            detectedAt: .now
        )
        h.conflictStore.setRecord(record, for: cardID)

        let serverEchoAt = ConflictHarness.t0.addingTimeInterval(200)
        let echoJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Local Title",
            lastActiveAt: ISO8601DateFormatter().string(from: serverEchoAt)
        )
        let board = ConflictBoard(remoteCardsJSON: "[]") // not used in resolution
        board.shouldReturn500ForPUT = false
        h.mock.handler = { req in
            let method = req.httpMethod ?? "?"
            let path = req.url?.path ?? ""
            if method == "PUT" && path.contains("/cards/9") {
                board.mutations // record call side-effect
                return (Data(echoJSON.utf8), .ok(for: req))
            }
            return try board.handler(req)
        }

        try await h.engine.resolveKeepMine(cardID: cardID)

        // PUT must have fired
        let putFired = h.mock.requests.contains { req in
            req.httpMethod == "PUT" && (req.url?.path.contains("/cards/9") == true)
        }
        #expect(putFired, "resolveKeepMine must PUT local card")

        // Pairing watermark updated to server echo
        let pairing = h.pairingStore.pairing(for: cardID)
        #expect(pairing?.fizzyUpdatedAt == serverEchoAt,
                "pairing watermark must equal server echo lastActiveAt")

        // card.modifiedAt == server echo
        #expect(card.modifiedAt == serverEchoAt,
                "card.modifiedAt must match server echo")

        // conflict record cleared
        #expect(h.conflictStore.record(for: cardID) == nil,
                "conflict record must be cleared after resolveKeepMine")
    }

    // MARK: Test 5: resolveTakeTheirs

    @Test("resolveTakeTheirs pulls fresh remote, repairs watermark and modifiedAt, clears record")
    func takeTheirs_pullsRemoteAndClearsConflict() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Local Title")
        let cardID = card.id!
        let remoteAt = ConflictHarness.t0.addingTimeInterval(60)

        // Seed conflict
        let record = ConflictRecord(
            id: cardID,
            fizzyNumber: 9,
            localTitle: "Local Title",
            localDescription: nil,
            remoteTitle: "Remote Title",
            remoteDescription: nil,
            detectedAt: .now
        )
        h.conflictStore.setRecord(record, for: cardID)

        // Fresh single-card fetch returns remote detail
        let remoteDetailJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Remote Title",
            description: "remote desc",
            lastActiveAt: ISO8601DateFormatter().string(from: remoteAt)
        )
        h.mock.handler = { req in
            let method = req.httpMethod ?? "?"
            let path = req.url?.path ?? ""
            if method == "GET" && path.hasSuffix("/cards/9") {
                return (Data(remoteDetailJSON.utf8), .ok(for: req))
            }
            Issue.record("unexpected: \(method) \(path) in takeTheirs test")
            return (Data(), .response(for: req, status: 500))
        }

        try await h.engine.resolveTakeTheirs(cardID: cardID)

        // card title matches remote
        #expect(card.title == "Remote Title", "card.title must be remote after takeTheirs")
        // card.modifiedAt matches remote.lastActiveAt
        #expect(card.modifiedAt == remoteAt, "card.modifiedAt must equal remote.lastActiveAt")
        // pairing watermark matches remote.lastActiveAt
        let pairing = h.pairingStore.pairing(for: cardID)
        #expect(pairing?.fizzyUpdatedAt == remoteAt,
                "pairing watermark must equal remote.lastActiveAt")
        // conflict record cleared
        #expect(h.conflictStore.record(for: cardID) == nil,
                "conflict record must be cleared after resolveTakeTheirs")
    }

    // MARK: Test 6: resolution converges — next sync is no-op

    @Test("after resolution, next sync produces itemsUpdated==0 and zero mutation requests")
    func resolutionConverges_nextSyncIsNoOp() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Local Title")
        let cardID = card.id!
        let remoteAt = ConflictHarness.t0.addingTimeInterval(60)

        // Seed conflict
        h.conflictStore.setRecord(
            ConflictRecord(id: cardID, fizzyNumber: 9,
                           localTitle: "Local Title", localDescription: nil,
                           remoteTitle: "Remote Title", remoteDescription: nil,
                           detectedAt: .now),
            for: cardID
        )

        // Setup the mock for resolveKeepMine (PUT echo)
        let resolvedAt = ConflictHarness.t0.addingTimeInterval(300)
        let echoJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Local Title",
            lastActiveAt: ISO8601DateFormatter().string(from: resolvedAt)
        )

        h.mock.handler = { req in
            let method = req.httpMethod ?? "?"
            let path = req.url?.path ?? ""
            if method == "PUT" && path.contains("/cards/9") {
                return (Data(echoJSON.utf8), .ok(for: req))
            }
            Issue.record("unexpected: \(method) \(path)")
            return (Data(), .response(for: req, status: 500))
        }
        try await h.engine.resolveKeepMine(cardID: cardID)

        // Second sync: remote reflects resolved state
        let remoteAfterJSON = conflictCardJSON(
            id: "fz9", number: 9, title: "Local Title",
            lastActiveAt: ISO8601DateFormatter().string(from: resolvedAt)
        )
        let board = ConflictBoard(remoteCardsJSON: "[\(remoteAfterJSON)]")
        h.mock.handler = { try board.handler($0) }

        let result2 = try await h.engine.sync(localBoardID: h.board.id!)

        #expect(result2.itemsUpdated == 0, "second sync must be a no-op (itemsUpdated==0)")
        #expect(result2.conflicts.isEmpty, "second sync must produce zero conflicts")
        let mutations2 = board.mutations.filter {
            $0.method == "PUT" || $0.path.contains("/triage") ||
            $0.path.contains("/taggings") || $0.path.contains("/assignments")
        }
        #expect(mutations2.isEmpty,
                "no mutation requests on second sync, got: \(mutations2)")
    }

    // MARK: Test 7: offline sync surfaces pending, does not report clean

    @Test("offline sync: handler throws URLError(.notConnectedToInternet) → scheduler ends .error not .idle")
    func offlineSyncSurfacesPending_doesNotReportClean() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        // Authenticated + paired provider
        let provider = FizzySyncProvider(
            authState: h.authState,
            mapping: FizzyBoardMapping(defaults: h.mappingDefaults),
            persistence: h.persistence,
            urlSession: h.mock.makeSession(),
            clock: ImmediateClock(),
            pairingStore: h.pairingStore,
            conflictStore: h.conflictStore
        )

        // Handler throws network error
        h.mock.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let scheduler = SyncScheduler(provider: provider, interval: .seconds(300))
        let activityState = scheduler.activityState

        // Directly call triggerSync to simulate what fireTick does
        await provider.triggerSync(activityState: activityState)

        // Must be in error phase, NOT idle-with-fresh-timestamp
        if case .error = activityState.phase {
            // pass
        } else {
            Issue.record("Expected .error phase after network failure, got \(activityState.phase)")
        }
    }

    // MARK: Test 8: pendingCount reflects failed pushes

    @Test("pendingPushCount reflects number of failed PUT operations (2 locally-edited cards, 500s)")
    func pendingCountReflectsFailedPushes() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        // Two locally-edited cards
        let card1 = h.seedConflictCard(localTitle: "Card One")
        let card2 = h.cardRepo.createCard(in: h.triage, title: "Card Two")
        try! h.persistence.viewContext.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fz10", fizzyNumber: 10,
                             fizzyUpdatedAt: ConflictHarness.t0),
            for: card2.id!
        )
        card2.modifiedAt = ConflictHarness.t0.addingTimeInterval(120)

        // Both remote cards at watermark (only local moved)
        let remote1 = conflictCardJSON(
            id: "fz9", number: 9, title: "Card One",
            lastActiveAt: ISO8601DateFormatter().string(from: ConflictHarness.t0)
        )
        let remote2 = conflictCardJSON(
            id: "fz10", number: 10, title: "Card Two",
            columnID: "FC1", columnName: "Triage",
            lastActiveAt: ISO8601DateFormatter().string(from: ConflictHarness.t0)
        )
        let board = ConflictBoard(remoteCardsJSON: "[\(remote1), \(remote2)]")
        board.shouldReturn500ForPUT = true
        h.mock.handler = { try board.handler($0) }

        let result = try await h.engine.sync(localBoardID: h.board.id!)

        // Two push errors in result
        let pushErrors = result.errors.filter { $0.hasPrefix("Push update") }
        #expect(pushErrors.count == 2, "expected 2 push errors, got: \(result.errors)")

        // activityState.pendingPushCount reflects the failures
        let provider = FizzySyncProvider(
            authState: h.authState,
            mapping: FizzyBoardMapping(defaults: h.mappingDefaults),
            persistence: h.persistence,
            urlSession: h.mock.makeSession(),
            clock: ImmediateClock(),
            pairingStore: h.pairingStore,
            conflictStore: h.conflictStore
        )
        let activityState = SyncActivityState()
        activityState.update(from: result, conflictStore: h.conflictStore)
        #expect(activityState.pendingPushCount == 2,
                "pendingPushCount must equal number of failed push errors")
    }
}

// MARK: - Task #29: pending step writes retry on the provider tick

@Suite("FizzySyncProvider — steps retry on tick (task #29)", .serialized)
@MainActor
struct ProviderStepsRetryTests {

    @Test("provider tick re-pushes pending step writes and clears pendingWrite")
    func tickRetriesPendingSteps() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Steppy")
        card.fizzyNumber = 9

        let step = CardStep(context: h.persistence.viewContext)
        step.content = "updated content"
        step.completed = true
        step.sortOrder = 0
        step.pendingWrite = true
        step.fizzyStepID = "st1"
        step.card = card
        try h.persistence.viewContext.save()

        let provider = FizzySyncProvider(
            authState: h.authState,
            mapping: FizzyBoardMapping(defaults: h.mappingDefaults),
            persistence: h.persistence,
            urlSession: h.mock.makeSession(),
            clock: ImmediateClock(),
            pairingStore: h.pairingStore,
            conflictStore: h.conflictStore
        )

        h.mock.handler = { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "PUT", path.hasSuffix("/cards/9/steps/st1") {
                return (Data(#"{"id":"st1","content":"updated content","completed":true}"#.utf8), .ok(for: req))
            }
            Issue.record("unexpected request: \(req.httpMethod ?? "?") \(path)")
            return (Data(), .response(for: req, status: 500))
        }

        await provider.retryPendingSteps()

        #expect(step.pendingWrite == false, "successful re-push must clear pendingWrite")
    }

    @Test("failed step re-push keeps pendingWrite for the next tick")
    func failedRetryKeepsPending() async throws {
        let h = ConflictHarness()
        defer { h.tearDown() }

        let card = h.seedConflictCard(localTitle: "Steppy")
        card.fizzyNumber = 9

        let step = CardStep(context: h.persistence.viewContext)
        step.content = "won't land"
        step.completed = false
        step.sortOrder = 0
        step.pendingWrite = true
        step.fizzyStepID = "st1"
        step.card = card
        try h.persistence.viewContext.save()

        let provider = FizzySyncProvider(
            authState: h.authState,
            mapping: FizzyBoardMapping(defaults: h.mappingDefaults),
            persistence: h.persistence,
            urlSession: h.mock.makeSession(),
            clock: ImmediateClock(),
            pairingStore: h.pairingStore,
            conflictStore: h.conflictStore
        )

        h.mock.handler = { req in
            (Data(), .response(for: req, status: 500))
        }

        await provider.retryPendingSteps()

        #expect(step.pendingWrite == true, "failed re-push must stay pending")
    }
}
