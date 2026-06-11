import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Shared helpers for the marker-adoption + resilience suites

/// Builds a paired board + engine wired to MockURLProtocol. Mirrors the
/// Harness pattern used throughout FizzySyncEngineTests.swift.
@MainActor
private struct AdoptionHarness {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column
    let engine: FizzySyncEngine
    let suiteName: String
    let authState: FizzyAuthState
    let mappingDefaults: UserDefaults

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
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

private let triageColumnsJSON = #"[{"id":"FCLOCAL","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-06-01T00:00:00Z"}]"#

// MARK: - Issue #14: marker-based deterministic orphan adoption

@Suite("FizzySyncEngine — marker-based adoption (issue #14)", .serialized)
@MainActor
struct FizzySyncEngineMarkerAdoptionTests {

    @Test("POSTed card descriptions carry the <!--fk:UUID--> adoption marker")
    func postCarriesMarker() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let withDesc = h.cardRepo.createCard(in: h.column, title: "WithDesc")
        withDesc.cardDescription = "Hello"
        let noDesc = h.cardRepo.createCard(in: h.column, title: "NoDesc")
        try h.persistence.viewContext.save()
        let withDescUUID = try #require(withDesc.id)
        let noDescUUID = try #require(noDesc.id)

        var postedDescriptionsByTitle: [String: String] = [:]
        var nextNumber = 40
        MockURLProtocol.handler = { req in
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
                    postedDescriptionsByTitle[title] = payload?["description"] as? String ?? "(nil)"
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
        #expect(postedDescriptionsByTitle["WithDesc"] == "Hello\n\n<!--fk:\(withDescUUID.uuidString)-->")
        #expect(postedDescriptionsByTitle["NoDesc"] == "<!--fk:\(noDescUUID.uuidString)-->")
    }

    @Test("pull adopts an unpaired local by marker, strips locally, marker persists remotely")
    func pullAdoptsByMarker() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Local card whose title and createdAt do NOT match the remote —
        // the legacy ±60s heuristic cannot pair these; only the marker can.
        let card = h.cardRepo.createCard(in: h.column, title: "Local title")
        card.cardDescription = "My body"
        try h.persistence.viewContext.save()
        let localUUID = try #require(card.id)

        let remote = remoteCardDict(
            id: "fzM", number: 9, title: "Remote title",
            description: "My body\n\n<!--fk:\(localUUID.uuidString)-->",
            createdAtISO: "2026-01-01T00:00:00Z", lastActiveISO: "2026-01-02T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _):
                Issue.record("no strip-PUT — markers persist remotely by design (issue #21)")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(result.itemsCreated == 0, "no pull-created duplicate, no POST")
        #expect(card.fizzyID == "fzM")
        #expect(card.fizzyNumber == 9)
        #expect(card.cardDescription?.contains("<!--fk:") != true, "local copy never contains markers")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "adoption must not duplicate the card locally")
    }

    @Test("adoption holds across repeated syncs — marker persists remotely, no strip-PUT churn")
    func adoptionStableWithPersistentMarker() async throws {
        // Inverts the pre-#21 "strip-PUT failure retries" coverage: there is
        // no strip-PUT anymore. The remote keeps serving the marker on every
        // sync and the engine must stay quiet — adopt once, then no PUTs, no
        // POSTs, no spurious updates.
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Local title")
        card.cardDescription = "Body"
        try h.persistence.viewContext.save()
        let localUUID = try #require(card.id)

        let remote = remoteCardDict(
            id: "fzM", number: 9, title: "Remote title",
            description: "Body\n\n<!--fk:\(localUUID.uuidString)-->",
            createdAtISO: "2026-01-01T00:00:00Z", lastActiveISO: "2026-01-02T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _):
                Issue.record("no strip-PUT — markers persist remotely by design (issue #21)")
                return (Data(), .response(for: req, status: 500))
            case ("POST", _):
                Issue.record("adopted card must not be POSTed")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let first = try await h.engine.sync()
        #expect(first.errors.isEmpty)
        #expect(card.fizzyID == "fzM", "marker adoption pairs the card")

        // The marker is still on the remote — the next sync must be a no-op,
        // not an echo loop (no PUT/POST; handler records any as an issue).
        let second = try await h.engine.sync()
        #expect(second.errors.isEmpty)
        #expect(second.itemsUpdated == 0, "steady state — nothing to update")
        #expect(card.fizzyID == "fzM")
        #expect(card.cardDescription?.contains("<!--fk:") != true, "local copy never contains markers")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }

    @Test("marker matching no local card → created normally, marker stripped locally, no error")
    func unownedMarkerCreatesCardNormally() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let strangerUUID = UUID()
        let remote = remoteCardDict(
            id: "fzZ", number: 5, title: "Stray",
            description: "Body text\n\n<!--fk:\(strangerUUID.uuidString)-->",
            createdAtISO: "2026-06-01T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?") — stripping an unowned marker is not our job")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(result.itemsCreated == 1)
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        let stray = try #require(cards.first { $0.fizzyID == "fzZ" })
        #expect(stray.cardDescription == "Body text", "local copies never contain markers")
    }

    @Test("marker beats the ±60s heuristic when the heuristic would mismatch")
    func markerWinsOverHeuristic() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let remoteCreated = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        // Card A: same title, createdAt within ±60s of the remote — the
        // legacy heuristic would claim it. WRONG owner.
        let cardA = h.cardRepo.createCard(in: h.column, title: "Dup")
        cardA.createdAt = remoteCreated.addingTimeInterval(10)
        // Card B: same title but created 10 minutes away — outside the
        // heuristic window. It is the true owner per the marker.
        let cardB = h.cardRepo.createCard(in: h.column, title: "Dup")
        cardB.createdAt = remoteCreated.addingTimeInterval(-600)
        try h.persistence.viewContext.save()
        let ownerUUID = try #require(cardB.id)

        let remote = remoteCardDict(
            id: "fzR", number: 11, title: "Dup",
            description: "<!--fk:\(ownerUUID.uuidString)-->",
            createdAtISO: "2026-06-01T00:00:00Z"
        )
        var postCount = 0
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _):
                Issue.record("no strip-PUT — markers persist remotely by design (issue #21)")
                return (Data(), .response(for: req, status: 500))
            case ("POST", _):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/12"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/12"):
                let dict = remoteCardDict(
                    id: "fzNEW", number: 12, title: "Dup",
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
        #expect(cardB.fizzyID == "fzR", "marker owner B adopts the remote, not heuristic match A")
        #expect(cardA.fizzyID == "fzNEW", "A is a genuinely new card → POSTed")
        #expect(postCount == 1)
    }
}

// MARK: - Issue #15: sync resilience

@Suite("FizzySyncEngine — sync resilience (issue #15)", .serialized)
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

        MockURLProtocol.handler = { req in
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

    @Test("save failure after POST → next sync adopts by marker instead of re-POSTing")
    func saveFailureDoesNotDuplicateOnNextSync() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        try h.persistence.viewContext.save()

        // Stateful mock: POSTed card joins the remote list verbatim
        // (marker and all), PUT updates its description.
        var postCount = 0
        var putCount = 0
        var storedRemote: [String: Any]?
        MockURLProtocol.handler = { req in
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
                storedRemote = remoteCardDict(
                    id: "fzH", number: 21,
                    title: payload?["title"] as? String ?? "?",
                    description: payload?["description"] as? String,
                    createdAtISO: "2026-06-01T00:00:00Z"
                )
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/21"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/21"):
                return (jsonData(storedRemote!), .ok(for: req))
            case ("PUT", let p?) where p.hasSuffix("/cards/21"):
                putCount += 1
                let payload = cardWritePayload(of: req)
                storedRemote?["description"] = payload?["description"] ?? NSNull()
                storedRemote?["title"] = payload?["title"] ?? "?"
                return (jsonData(storedRemote!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: POST succeeds, but the save fails (poisoned context) —
        // the in-memory pairing is lost as if the app died before saving.
        let poison = Card(context: h.persistence.viewContext)
        poison.id = UUID()
        poison.title = nil

        let first = try await h.engine.sync()
        #expect(postCount == 1)
        #expect(first.errors.contains { $0.localizedCaseInsensitiveContains("save") })

        // Simulate process restart: unsaved changes (pairing + poison) gone.
        h.persistence.viewContext.rollback()
        #expect(card.fizzyID == nil, "pairing was never persisted")

        // Sync 2: the remote card still carries the marker → adopted, not
        // re-POSTed. This is the end-to-end duplicate-prevention backstop.
        let second = try await h.engine.sync()

        #expect(postCount == 1, "no second POST — marker adoption prevents the duplicate")
        #expect(second.errors.isEmpty)
        #expect(card.fizzyID == "fzH")
        #expect(card.fizzyNumber == 21)
        #expect(putCount == 0, "no strip-PUT — markers persist remotely by design (issue #21)")
        #expect(card.cardDescription == "Body")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero — locally and remotely")
    }

    @Test("CloudKit-clobbered pairing heals by marker — no duplicate POST")
    func cloudKitClobberHealsWithoutDuplicate() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Production shape of issue #21: a CloudKit import clobbers ALL
        // synced pairing fields (fizzyID, fizzyNumber, fizzyUpdatedAt) to
        // nil/zero after a successful pairing. Re-pair-by-number can't help
        // (number is gone too) and the card's createdAt is backdated 10
        // minutes from the remote's so the title±60s orphan heuristic can't
        // claim the remote either — the persistent marker is the only path
        // that can heal instead of duplicating.
        let remoteCreated = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        card.createdAt = remoteCreated.addingTimeInterval(-600)
        try h.persistence.viewContext.save()

        // Faithful stateful server: POSTed cards join the remote store
        // verbatim (markers included), PUTs are applied to the stored state.
        // This keeps the test honest in both worlds: pre-#21 code strips the
        // marker via PUT during sync 2 and duplicates in sync 3; post-#21
        // code never strips, so the marker survives and adoption heals.
        var postCount = 0
        var nextNumber = 20
        var remotesByNumber: [Int: [String: Any]] = [:]
        MockURLProtocol.handler = { req in
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
                remotesByNumber[nextNumber] = remoteCardDict(
                    id: "fz-\(nextNumber)", number: nextNumber,
                    title: payload?["title"] as? String ?? "?",
                    description: payload?["description"] as? String,
                    createdAtISO: "2026-06-01T00:00:00Z"
                )
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
                let number = Int((p as NSString).lastPathComponent) ?? 0
                guard remotesByNumber[number] != nil else {
                    Issue.record("PUT for unknown card number \(number)")
                    return (Data(), .response(for: req, status: 404))
                }
                let payload = cardWritePayload(of: req)
                remotesByNumber[number]?["title"] = payload?["title"] ?? "?"
                remotesByNumber[number]?["description"] = payload?["description"] ?? NSNull()
                return (jsonData(remotesByNumber[number]!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: the local card pairs via POST.
        let first = try await h.engine.sync()
        #expect(first.errors.isEmpty)
        #expect(postCount == 1)
        #expect(card.fizzyID == "fz-21")

        // Sync 2: a steady-state cycle while the pairing is intact — this is
        // where pre-#21 code stripped the marker remotely, defeating the net.
        let second = try await h.engine.sync()
        #expect(second.errors.isEmpty)

        // Between syncs: the CloudKit import clobbers the pairing fields.
        card.fizzyID = nil
        card.fizzyNumber = 0
        card.fizzyUpdatedAt = nil
        try h.persistence.viewContext.save()

        // Sync 3: the persistent marker must heal the pairing — never POST.
        let third = try await h.engine.sync()

        #expect(postCount == 1, "no duplicate POST — marker adoption heals the clobbered pairing")
        #expect(third.errors.isEmpty)
        #expect(card.fizzyID == "fz-21", "fizzyID restored from the remote twin")
        #expect(card.fizzyNumber == 21, "fizzyNumber restored from the remote twin")
        let remoteTwin = try #require(remotesByNumber[21])
        let twinLastActive = ISO8601DateFormatter().date(
            from: try #require(remoteTwin["last_active_at"] as? String)
        )
        #expect(card.fizzyUpdatedAt == twinLastActive, "fizzyUpdatedAt restored from the remote twin")
        #expect(remotesByNumber.count == 1, "exactly one Hero remotely")
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero locally")
    }

    @Test("clobbered fizzyID re-pairs via surviving fizzyNumber instead of duplicating")
    func clobberedFizzyIDRepairsByNumber() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Simulates a CloudKit merge that nulled fizzyID but left fizzyNumber.
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.fizzyID = nil
        card.fizzyNumber = 7
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()

        let remote = remoteCardDict(
            id: "fz7", number: 7, title: "Hero (renamed remotely)",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        var postCount = 0
        var putPaths: [String] = []
        MockURLProtocol.handler = { req in
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

        #expect(postCount == 0, "re-pair, never re-POST")
        #expect(card.fizzyID == "fz7", "fizzyID restored from the number match")
        #expect(result.itemsCreated == 0, "no pull-created duplicate")
        #expect(putPaths == ["/ACCT/cards/7"], "local edit pushed via LWW after re-pairing")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }
}
