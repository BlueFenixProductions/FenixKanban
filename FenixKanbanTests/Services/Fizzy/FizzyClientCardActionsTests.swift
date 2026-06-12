import Testing
import Foundation
@testable import FenixKanban

// Tests for the FizzyClient card-action convenience methods.
// Wire shapes per fizzy docs/api/sections/cards.md and pins.md.

private final class FixtureLocatorCardActions {}

@Suite("FizzyClient — card actions")
struct FizzyClientCardActionsTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: ImmediateClock()
        )
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorCardActions.self)
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

    /// Decodes the request's JSON body (URLProtocol exposes it as a stream).
    private func jsonBody(of request: URLRequest) -> [String: String]? {
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
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    // MARK: - Card detail

    @Test("GET /:account/cards/:number decodes the verbatim doc response")
    func cardDetailVerbatimDocShape() async throws {
        // Fixture card_detail_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/cards.md, section "GET /:account_slug/cards/:card_number".
        let data = try loadFixture("card_detail_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
            return (data, .ok(for: req))
        }

        let card = try await makeClient().card(number: 1)
        #expect(card.id == "03f5vaeq985jlvwv3arl4srq2")
        #expect(card.number == 1)
        #expect(card.title == "First!")
        #expect(card.closed == false)
        #expect(card.column?.name == "In Progress")
        #expect(card.column?.color == FizzyColor(name: "Lime", value: "var(--color-card-4)"))
        #expect(card.steps?.count == 2)
        #expect(card.steps?.first?.content == "This is the first step")
        #expect(card.tags == ["programming"])
    }

    // MARK: - Delete

    @Test("DELETE /:account/cards/:number deletes the card")
    func deleteCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/7")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteCard(number: 7)
        #expect(mock.requests.count == 1)
    }

    // MARK: - Closure

    @Test("POST /closure closes a card (204, no body)")
    func closeCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/closure")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().closeCard(number: 4)
        #expect(mock.requests.count == 1)
    }

    @Test("DELETE /closure reopens a card")
    func reopenCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/closure")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().reopenCard(number: 4)
    }

    @Test("action POST surfaces HTTP errors as FizzyError")
    func actionPostErrorMapping() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 404)) }
        await #expect(throws: FizzyError.notFound) {
            try await makeClient().closeCard(number: 999)
        }
    }

    // MARK: - Not now

    @Test("POST /not_now postpones a card")
    func postponeCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/not_now")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().postponeCard(number: 4)
    }

    // MARK: - Triage

    @Test("POST /triage sends column_id body")
    func triageCard() async throws {
        let body = LockedBox<[String: String]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/triage")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            body.value = self.jsonBody(of: req)
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().triageCard(number: 4, columnID: "03f5v9zkft4hj9qq0lsn9ohcn")
        #expect(body.value == ["column_id": "03f5v9zkft4hj9qq0lsn9ohcn"])
    }

    @Test("DELETE /triage sends a card back to triage")
    func untriageCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/triage")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().untriageCard(number: 4)
    }

    // MARK: - Move to board

    @Test("PUT /board sends board_id and returns the moved card")
    func moveCardToBoard() async throws {
        let data = try loadFixture("card_detail_doc")
        let body = LockedBox<[String: String]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/board")
            body.value = self.jsonBody(of: req)
            return (data, .ok(for: req))
        }
        let moved = try await makeClient().moveCard(number: 4, toBoardID: "03f5v9zkft4hj9qq0lsn9ohcm")
        #expect(body.value == ["board_id": "03f5v9zkft4hj9qq0lsn9ohcm"])
        #expect(moved.id == "03f5vaeq985jlvwv3arl4srq2")
    }

    // MARK: - Watch

    @Test("POST /watch subscribes the current user")
    func watchCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/watch")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().watchCard(number: 4)
    }

    @Test("DELETE /watch unsubscribes the current user")
    func unwatchCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/watch")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().unwatchCard(number: 4)
    }

    // MARK: - Goldness

    @Test("POST /goldness marks a card golden")
    func markGolden() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/goldness")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().markCardGolden(number: 4)
    }

    @Test("DELETE /goldness removes golden status")
    func unmarkGolden() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/goldness")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().unmarkCardGolden(number: 4)
    }

    // MARK: - Pins

    @Test("POST /pin pins a card")
    func pinCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/pin")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().pinCard(number: 4)
    }

    @Test("DELETE /pin unpins a card")
    func unpinCard() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/pin")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().unpinCard(number: 4)
    }

    @Test("GET /:account/my/pins is account-scoped and decodes verbatim doc response")
    func myPinsVerbatimDocShape() async throws {
        // Fixture pins_doc.json is copied VERBATIM from fizzy
        // docs/api/sections/pins.md, section "GET /:account_slug/my/pins".
        // Note: unlike /my/identity, this /my path IS account-scoped per docs.
        let data = try loadFixture("pins_doc")
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/my/pins")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            return (data, .ok(for: req))
        }

        let pins = try await makeClient().myPins()
        #expect(pins.count == 1)
        #expect(pins.first?.id == "03f5vaeq985jlvwv3arl4srq2")
        #expect(pins.first?.title == "First!")
        #expect(pins.first?.golden == false)
    }

    // MARK: - Taggings

    @Test("POST /taggings sends tag_title body")
    func toggleTag() async throws {
        let body = LockedBox<[String: String]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/taggings")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            body.value = self.jsonBody(of: req)
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().toggleCardTag(number: 4, tagTitle: "programming")
        #expect(body.value == ["tag_title": "programming"])
    }

    // MARK: - Assignments

    @Test("POST /assignments sends assignee_id body")
    func toggleAssignment() async throws {
        let body = LockedBox<[String: String]?>(nil)
        mock.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/assignments")
            body.value = self.jsonBody(of: req)
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().toggleCardAssignment(number: 4, assigneeID: "03f5v9zjw7pz8717a4no1h8a7")
        #expect(body.value == ["assignee_id": "03f5v9zjw7pz8717a4no1h8a7"])
    }

    // MARK: - Image

    @Test("DELETE /image removes the card header image")
    func deleteCardImage() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/4/image")
            return (Data(), .response(for: req, status: 204))
        }
        try await makeClient().deleteCardImage(number: 4)
    }
}

/// Tiny reference box so the MockURLProtocol handler (a sync closure) can
/// pass captured request data back to the async test body.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
