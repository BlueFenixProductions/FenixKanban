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
    let pairingStore: FizzyCardPairingStore

    init() {
        MockURLProtocol.reset()
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
            context: persistence.viewContext, pairingStore: pairingStore
        )
    }

    func tearDown() {
        authState.clear()
        mappingDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: pairingStore.fileURL)
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
        MockURLProtocol.handler = { req in
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

    @Test("LWW push PUT preserves the local edit AND re-embeds the marker (issue #21)")
    func putReembedsMarkerWithLocalEdit() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Paired card with a local edit newer than the remote — LWW pushes.
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Edited body"
        card.fizzyID = "fzP"
        card.fizzyNumber = 9
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()
        let localUUID = try #require(card.id)

        let remote = remoteCardDict(
            id: "fzP", number: 9, title: "Hero",
            description: "Old body\n\n<!--fk:\(localUUID.uuidString)-->",
            createdAtISO: "2026-01-01T00:00:00Z",
            lastActiveISO: ISO8601DateFormatter().string(from: baseline)
        )
        var putDescriptions: [String] = []
        MockURLProtocol.handler = { req in
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
                updated["description"] = payload?["description"] ?? NSNull()
                return (jsonData(updated), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(putDescriptions.count == 1, "exactly one LWW push PUT")
        let putBody = try #require(putDescriptions.first)
        #expect(putBody.contains("Edited body"), "local edit preserved in the PUT payload")
        #expect(
            putBody.hasSuffix("<!--fk:\(localUUID.uuidString)-->"),
            "marker re-embedded — a local edit must not wipe the remote marker (issue #21)"
        )
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

        #expect(postCount == 0, "seeded pairing — never re-POST")
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fz7", "store seeded from the number hint")
        #expect(card.fizzyID == "fz7", "fizzyID hint healed")
        #expect(result.itemsCreated == 0)
        #expect(putPaths == ["/ACCT/cards/7"], "local edit pushed via LWW after seeding")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
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
        MockURLProtocol.handler = { req in
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
}
