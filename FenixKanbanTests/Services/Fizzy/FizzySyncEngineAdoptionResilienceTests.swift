import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Shared helpers for the marker-adoption + resilience suites

/// Builds a paired board + engine wired to MockURLProtocol. Mirrors the
/// Harness pattern used throughout FizzySyncEngineTests.swift.
@MainActor
private struct AdoptionHarness {
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

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        boardRepo = BoardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
        board = boardRepo.createBoard(name: "Roadmap")
        column = boardRepo.createColumn(in: board, name: "Triage")
        try! persistence.viewContext.save()

        let prefix = "test.fizzy.marker.\(UUID().uuidString)"
        authState = FizzyAuthState(keyPrefix: prefix)
        authState.setAccessToken("t")
        authState.setAccountSlug("ACCT")

        suiteName = "test.fizzy.marker.mapping.\(UUID().uuidString)"
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

/// Reads a URLRequest's JSON body (URLProtocol exposes it as a stream) and
/// returns the nested `card` payload of a `{ "card": { ... } }` write.
private func cardWritePayload(of request: URLRequest) -> [String: Any]? {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var collected = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            collected.append(buffer, count: read)
        }
        data = collected
    }
    guard let data,
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return object["card"] as? [String: Any]
}

/// Wire-shaped remote card as a JSON dictionary (list-endpoint shape).
private func remoteCardDict(
    id: String, number: Int, title: String,
    description: String?, createdAtISO: String, lastActiveISO: String? = nil
) -> [String: Any] {
    [
        "id": id,
        "number": number,
        "title": title,
        "status": "published",
        "description": description as Any? ?? NSNull(),
        "description_html": NSNull(),
        "image_url": NSNull(),
        "has_attachments": false,
        "tags": [String](),
        "golden": false,
        "last_active_at": lastActiveISO ?? createdAtISO,
        "created_at": createdAtISO,
        "url": "https://fizzy.bluefenix.net/ACCT/cards/\(number)"
    ]
}

private func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

/// Mimics Fizzy's ActionText rich-text sanitizer: HTML comments are
/// stripped ON WRITE (verified against the production DB, 2026-06-10 —
/// issue #21 forensics: 41 marker-POSTed cards, zero retained markers).
/// Every stateful mock MUST pass stored descriptions through this so a
/// write→read round-trip can never certify a fictional server again.
private func sanitizedDescription(_ raw: Any?) -> Any {
    guard let s = raw as? String, !s.isEmpty else { return NSNull() }
    let stripped = s.replacingOccurrences(
        of: #"(?:\n\n)?<!--[\s\S]*?-->"#, with: "", options: .regularExpression
    )
    return stripped.isEmpty ? NSNull() : stripped
}

private let triageColumnsJSON = #"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#

// MARK: - Issue #21 A′: pairing store adoption & wire hygiene

@Suite("FizzySyncEngine — pairing store adoption & wire hygiene (issue #21 A′)", .serialized)
@MainActor
struct FizzySyncEngineMarkerAdoptionTests {

    @Test("POST sends the description verbatim — no marker, wire-clean")
    func postSendsCleanDescription() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let withDesc = h.cardRepo.createCard(in: h.column, title: "WithDesc")
        withDesc.cardDescription = "Hello"
        _ = h.cardRepo.createCard(in: h.column, title: "NoDesc")
        try h.persistence.viewContext.save()

        // Maps title → posted description string (absent/NSNull description left absent from the dict).
        var postedStringDescriptions: [String: String] = [:]
        var postedTitles: Set<String> = []
        var nextNumber = 40
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let payload = cardWritePayload(of: req)
                if let title = payload?["title"] as? String {
                    postedTitles.insert(title)
                    if let desc = payload?["description"] as? String {
                        postedStringDescriptions[title] = desc
                    }
                }
                nextNumber += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(nextNumber)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let number = Int((p as NSString).lastPathComponent) ?? 0
                let dict = remoteCardDict(
                    id: "fz-\(number)", number: number, title: "x",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(postedStringDescriptions["WithDesc"] == "Hello", "verbatim — no marker suffix")
        #expect(postedTitles.contains("NoDesc"), "NoDesc was posted")
        #expect(postedStringDescriptions["NoDesc"] == nil, "nil description stays nil — not a bare marker")
    }

    @Test("store-paired card stays quiet across repeated syncs — no churn")
    func pairedSteadyStateStaysQuiet() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        card.modifiedAt = baseline
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzM", fizzyNumber: 9, fizzyUpdatedAt: baseline),
            for: cardUUID
        )

        let remote = remoteCardDict(
            id: "fzM", number: 9, title: "Hero",
            description: "Body", createdAtISO: "2026-01-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _), ("POST", _):
                Issue.record("steady state must not write: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        for _ in 0..<2 {
            let result = try await h.engine.sync()
            #expect(result.errors.isEmpty)
            #expect(result.itemsUpdated == 0)
            #expect(result.itemsCreated == 0)
        }
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }

    @Test("remote descriptions import verbatim — no marker stripping on pull")
    func remoteDescriptionImportsVerbatim() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Production remotes never contain markers (the server's sanitizer
        // strips HTML comments on write) — so the engine performs no
        // stripping of its own. What the server returns is what we store.
        let remote = remoteCardDict(
            id: "fzZ", number: 5, title: "Stray",
            description: "Body text",
            createdAtISO: "2026-06-01T00:00:00Z"
        )
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(result.itemsCreated == 1)
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        let stray = try #require(cards.first { $0.title == "Stray" })
        #expect(stray.cardDescription == "Body text")
        #expect(h.pairingStore.pairing(for: try #require(stray.id))?.fizzyID == "fzZ")
    }

}

// MARK: - Issues #15/#21 A′: sync resilience

@Suite("FizzySyncEngine — sync resilience (issues #15/#21 A′)", .serialized)
@MainActor
struct FizzySyncEngineResilienceTests {

    @Test("context.save() failure during sync surfaces in FizzySyncResult.errors")
    func saveFailureSurfacesInErrors() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Poison the context: title is non-optional in the model, so a nil
        // title fails validateForInsert when the engine saves.
        let poison = Card(context: h.persistence.viewContext)
        poison.id = UUID()
        poison.title = nil

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.count == 1)
        #expect(result.errors.first?.localizedCaseInsensitiveContains("save") == true)

        h.persistence.viewContext.delete(poison)
    }

    @Test("save failure after POST cannot duplicate — the pairing store persists independently")
    func saveFailureDoesNotDuplicateOnNextSync() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        // Stateful sanitizer-faithful mock: POSTed cards join the remote
        // list with HTML comments stripped (as production Fizzy does).
        var postCount = 0
        var storedRemote: [String: Any]?
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let list = storedRemote.map { [$0] } ?? []
                return (jsonData(list), .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let payload = cardWritePayload(of: req)
                var dict = remoteCardDict(
                    id: "fzH", number: 21,
                    title: payload?["title"] as? String ?? "?",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                dict["description"] = sanitizedDescription(payload?["description"])
                storedRemote = dict
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/21"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/21"):
                return (jsonData(storedRemote!), .ok(for: req))
            case ("PUT", let p?) where p.hasSuffix("/cards/21"):
                let payload = cardWritePayload(of: req)
                storedRemote?["description"] = sanitizedDescription(payload?["description"])
                storedRemote?["title"] = payload?["title"] ?? "?"
                return (jsonData(storedRemote!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: POST succeeds, but the context save fails (poisoned
        // context) — unsaved attribute changes are lost as if the app died.
        let poison = Card(context: h.persistence.viewContext)
        poison.id = UUID()
        poison.title = nil

        let first = try await h.engine.sync()
        #expect(postCount == 1)
        #expect(first.errors.contains { $0.localizedCaseInsensitiveContains("save") })

        // Simulate process restart: unsaved context changes are gone — but
        // the pairing store already persisted the pairing.
        h.persistence.viewContext.rollback()
        #expect(card.fizzyID == nil, "hint attribute was never saved")
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fzH", "store write survived")

        // Sync 2: no duplicate POST. (The LWW push may PUT — rollback
        // restored a modifiedAt newer than the stored fizzyUpdatedAt; that
        // is correct push-my-edit behavior, not duplication.)
        let second = try await h.engine.sync()
        #expect(postCount == 1, "no second POST — the store prevented the duplicate")
        #expect(second.errors.isEmpty)
        #expect(card.fizzyID == "fzH", "hint healed from the store")
        #expect(card.fizzyNumber == 21)

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero — locally and remotely")
    }

    @Test("CloudKit attribute clobber cannot unpair — the store is the authority, hints heal")
    func cloudKitClobberCannotUnpair() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Production shape of issue #21: a CloudKit import clobbers ALL
        // synced pairing attributes to nil/zero after a successful pairing.
        // The server strips adoption markers (sanitizer-faithful mock), the
        // number is zeroed (no re-pair-by-number), and createdAt is
        // backdated 10 minutes (the title±60s heuristic can't claim the
        // remote). Only the local pairing store can prevent a duplicate.
        let remoteCreated = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        card.createdAt = remoteCreated.addingTimeInterval(-600)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        var postCount = 0
        var putCount = 0
        var nextNumber = 20
        var remotesByNumber: [Int: [String: Any]] = [:]
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData(Array(remotesByNumber.values)), .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                nextNumber += 1
                let payload = cardWritePayload(of: req)
                var dict = remoteCardDict(
                    id: "fz-\(nextNumber)", number: nextNumber,
                    title: payload?["title"] as? String ?? "?",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                dict["description"] = sanitizedDescription(payload?["description"])
                remotesByNumber[nextNumber] = dict
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(nextNumber)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let number = Int((p as NSString).lastPathComponent) ?? 0
                guard let stored = remotesByNumber[number] else {
                    Issue.record("GET for unknown card number \(number)")
                    return (Data(), .response(for: req, status: 404))
                }
                return (jsonData(stored), .ok(for: req))
            case ("PUT", let p?) where p.contains("/cards/"):
                putCount += 1
                let number = Int((p as NSString).lastPathComponent) ?? 0
                guard remotesByNumber[number] != nil else {
                    Issue.record("PUT for unknown card number \(number)")
                    return (Data(), .response(for: req, status: 404))
                }
                let payload = cardWritePayload(of: req)
                remotesByNumber[number]?["title"] = payload?["title"] ?? "?"
                remotesByNumber[number]?["description"] = sanitizedDescription(payload?["description"])
                return (jsonData(remotesByNumber[number]!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: the local card pairs via POST — into the pairing store.
        let first = try await h.engine.sync()
        #expect(first.errors.isEmpty)
        #expect(postCount == 1)
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fz-21")
        #expect(card.fizzyID == "fz-21", "hint attributes written at pairing time")

        // Sync 2: steady-state cycle while everything is intact.
        let second = try await h.engine.sync()
        #expect(second.errors.isEmpty)

        // Between syncs: a CloudKit import clobbers ALL hint attributes.
        card.fizzyID = nil
        card.fizzyNumber = 0
        card.fizzyUpdatedAt = nil
        try h.persistence.viewContext.save()

        // Sync 3: the store still owns the pairing — never POST.
        let third = try await h.engine.sync()
        #expect(postCount == 1, "no duplicate POST — the pairing store is CloudKit-proof")
        #expect(third.errors.isEmpty)
        #expect(card.fizzyID == "fz-21", "fizzyID hint healed from the store")
        #expect(card.fizzyNumber == 21, "fizzyNumber hint healed from the store")
        #expect(remotesByNumber.count == 1, "exactly one Hero remotely")
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero locally")

        // Sync 4: hint healing must not have bumped modifiedAt — the next
        // cycle stays completely quiet (no PUT/POST echo).
        let putsBefore = putCount
        let fourth = try await h.engine.sync()
        #expect(fourth.errors.isEmpty)
        #expect(postCount == 1)
        #expect(putCount == putsBefore, "hint healing causes no echo-PUT")
    }

    @Test("LWW push PUT sends the edited description verbatim — no marker")
    func putSendsCleanDescription() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Edited body"
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzP", fizzyNumber: 9, fizzyUpdatedAt: baseline),
            for: cardUUID
        )

        let remote = remoteCardDict(
            id: "fzP", number: 9, title: "Hero",
            description: "Old body",
            createdAtISO: "2026-01-01T00:00:00Z",
            lastActiveISO: ISO8601DateFormatter().string(from: baseline)
        )
        var putDescriptions: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", let p?) where p.hasSuffix("/cards/9"):
                let payload = cardWritePayload(of: req)
                putDescriptions.append(payload?["description"] as? String ?? "(nil)")
                var updated = remote
                updated["title"] = payload?["title"] ?? "?"
                updated["description"] = sanitizedDescription(payload?["description"])
                return (jsonData(updated), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(putDescriptions == ["Edited body"], "exactly one LWW push PUT, description verbatim")
    }

    @Test("cold store seeds from a number-only hint (pre-A′ clobber residue)")
    func coldStoreSeedsByNumberHint() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Pre-A′ data shape: fizzyID clobbered to nil, number survived.
        // Seeding resolves the number against the remote list.
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.fizzyID = nil
        card.fizzyNumber = 7
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        let remote = remoteCardDict(
            id: "fz7", number: 7, title: "Hero (renamed remotely)",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        var postCount = 0
        var putPaths: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", let p?):
                putPaths.append(p)
                var updated = remote
                updated["title"] = "Hero"
                return (jsonData(updated), .ok(for: req))
            case ("POST", _):
                postCount += 1
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(postCount == 0, "seeded pairing — never re-POST")
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fz7", "store seeded from the number hint")
        #expect(card.fizzyID == "fz7", "fizzyID hint healed")
        #expect(result.itemsCreated == 0)
        #expect(putPaths == ["/ACCT/cards/7"], "local edit pushed via LWW after seeding")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }

    @Test("partially-warm store still seeds remaining attribute hints — no duplicate POST")
    func partialStoreStillSeedsRemainingHints() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Card A is already in the store (paired post-A′). Card B was paired
        // pre-A′ — attribute hints only. A store with one entry must STILL
        // adopt B's hints instead of POSTing a duplicate (partial first
        // sync after upgrade / late CloudKit import).
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let cardA = h.cardRepo.createCard(in: h.column, title: "Alpha")
        cardA.modifiedAt = baseline
        let cardB = h.cardRepo.createCard(in: h.column, title: "Beta")
        cardB.fizzyID = "fzB"
        cardB.fizzyNumber = 8
        cardB.fizzyUpdatedAt = baseline
        cardB.modifiedAt = baseline
        try h.persistence.viewContext.save()
        let aUUID = try #require(cardA.id)
        let bUUID = try #require(cardB.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzA", fizzyNumber: 7, fizzyUpdatedAt: baseline),
            for: aUUID
        )

        let remoteA = remoteCardDict(
            id: "fzA", number: 7, title: "Alpha",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        let remoteB = remoteCardDict(
            id: "fzB", number: 8, title: "Beta",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remoteA, remoteB]), .ok(for: req))
            case ("PUT", _), ("POST", _):
                Issue.record("hinted card must be adopted, not written: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(h.pairingStore.pairing(for: bUUID)?.fizzyID == "fzB", "B's hints seeded despite warm store")
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 2, "no local duplicates either")
    }

    @Test("cold store seeds from full attribute hints — upgrade/reinstall/second device")
    func coldStoreSeedsFromAttributeHints() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Pre-A′ paired card: attributes intact, store empty (first launch
        // of the A′ build — or a second device that got the card via
        // CloudKit). The sync must adopt the hints, not POST a duplicate.
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.fizzyID = "fz9"
        card.fizzyNumber = 9
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        #expect(h.pairingStore.isEmpty)

        let remote = remoteCardDict(
            id: "fz9", number: 9, title: "Hero",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _), ("POST", _):
                Issue.record("seeded pairing must not write: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        let seeded = h.pairingStore.pairing(for: cardUUID)
        #expect(seeded?.fizzyID == "fz9")
        #expect(seeded?.fizzyNumber == 9)
        #expect(seeded?.fizzyUpdatedAt == baseline)
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }

    @Test("deleteColumn cascade tombstones from the store and clears pairings — even with clobbered hints")
    func deleteColumnCascadeUsesStorePairing() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Doomed by cascade")
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzC", fizzyNumber: 34, fizzyUpdatedAt: .now),
            for: cardUUID
        )
        // CloudKit clobbered the hint attributes — the store still knows.
        card.fizzyID = nil
        card.fizzyNumber = 0

        h.boardRepo.deleteColumn(h.column)

        let tombstones = try h.persistence.viewContext.fetch(CardTombstone.fetchRequest())
        #expect(tombstones.map(\.fizzyNumber) == [34], "cascade tombstone number comes from the store")
        #expect(h.pairingStore.pairing(for: cardUUID) == nil, "pairing removed on cascade delete")
    }

    @Test("deleteCard tombstones from the store and clears the pairing — even with clobbered hints")
    func deleteUsesStorePairingWhenHintsClobbered() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Doomed")
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzD", fizzyNumber: 21, fizzyUpdatedAt: .now),
            for: cardUUID
        )
        // CloudKit clobbered the hint attributes — the store still knows.
        card.fizzyID = nil
        card.fizzyNumber = 0

        h.cardRepo.deleteCard(card)

        let tombstones = try h.persistence.viewContext.fetch(CardTombstone.fetchRequest())
        #expect(tombstones.map(\.fizzyNumber) == [21], "tombstone number comes from the store")
        #expect(h.pairingStore.pairing(for: cardUUID) == nil, "pairing removed on delete")
    }
}

// MARK: - Issue #21 A′: first-sync modes pair through the store

@Suite("FizzySyncEngine — first-sync modes pair through the store (issue #21 A′)", .serialized)
@MainActor
struct FizzySyncEngineFirstSyncStoreTests {

    @Test("push mode skips store-paired cards and records new pairings in the store")
    func pushModeUsesStore() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // One card already paired (store only — no attributes), one new.
        let paired = h.cardRepo.createCard(in: h.column, title: "AlreadyPaired")
        let fresh = h.cardRepo.createCard(in: h.column, title: "Fresh")
        try h.persistence.viewContext.save()
        let pairedUUID = try #require(paired.id)
        let freshUUID = try #require(fresh.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzOld", fizzyNumber: 3, fizzyUpdatedAt: .now),
            for: pairedUUID
        )

        var postedTitles: [String] = []
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let payload = cardWritePayload(of: req)
                postedTitles.append(payload?["title"] as? String ?? "?")
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/50"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/50"):
                let dict = remoteCardDict(
                    id: "fzNew", number: 50, title: "Fresh",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(result.errors.isEmpty)
        #expect(postedTitles == ["Fresh"], "store-paired card is not re-POSTed")
        #expect(h.pairingStore.pairing(for: freshUUID)?.fizzyID == "fzNew", "new pairing recorded in the store")
        #expect(fresh.fizzyID == "fzNew", "hint attributes written")
    }

    @Test("replace mode clears the wiped cards' pairings and pairs the pulled ones in the store")
    func replaceModeResetsStore() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let old = h.cardRepo.createCard(in: h.column, title: "Old")
        try h.persistence.viewContext.save()
        let oldUUID = try #require(old.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzGone", fizzyNumber: 1, fizzyUpdatedAt: .now),
            for: oldUUID
        )

        let remote = remoteCardDict(
            id: "fzKeep", number: 2, title: "Kept",
            description: nil, createdAtISO: "2026-06-01T00:00:00Z"
        )
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.errors.isEmpty)
        #expect(h.pairingStore.pairing(for: oldUUID) == nil, "wiped card's pairing removed")
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        let kept = try #require(cards.first { $0.title == "Kept" })
        #expect(h.pairingStore.pairing(for: try #require(kept.id))?.fizzyID == "fzKeep")
    }

    @Test("merge mode pairs pushed cards in the store")
    func mergeModeRecordsPairings() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let localOnly = h.cardRepo.createCard(in: h.column, title: "LocalOnly")
        try h.persistence.viewContext.save()
        let localUUID = try #require(localOnly.id)

        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/60"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/60"):
                let dict = remoteCardDict(
                    id: "fzMerge", number: 60, title: "LocalOnly",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(result.errors.isEmpty)
        #expect(h.pairingStore.pairing(for: localUUID)?.fizzyID == "fzMerge")
    }
}
