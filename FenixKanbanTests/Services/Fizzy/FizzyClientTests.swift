import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyClient — auth + URL construction")
struct FizzyClientAuthTests {
    let mock = MockHTTPState()

    private func makeClient(token: String = "test-token", slug: String = "897362094") -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: token,
            accountSlug: slug,
            urlSession: session
        )
    }

    @Test("GET attaches Bearer header + interpolates :account_slug into path")
    func authAndSlug() async throws {
        mock.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"abc\""]))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)

        let req = try #require(mock.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/boards")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("paths starting with /my/ are NOT account-scoped (Fizzy convention)")
    func myPathsBypassSlug() async throws {
        mock.handler = { req in
            let body = #"{"accounts":[]}"#.data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/my/identity", as: FizzyIdentity.self)

        let req = try #require(mock.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/my/identity")
    }

    @Test("paths with /my prefix but no trailing slash DO get scoped")
    func myPrefixWithoutSlashIsScoped() async throws {
        mock.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/myth-busters", as: [FizzyBoard].self)

        let req = try #require(mock.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/myth-busters")
    }

    @Test("slug with leading slash (real wire shape) is handled correctly")
    func slugWithLeadingSlashIsHandled() async throws {
        // Regression: Fizzy's /my/identity returns slug as "/897362094" (leading
        // slash). The previous URL builder produced "//897362094/boards" which
        // parses as a protocol-relative URL with host=897362094.
        mock.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient(slug: "/897362094")
        _ = try await client.get("/boards", as: [FizzyBoard].self)

        let req = try #require(mock.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/boards")
        #expect(req.url?.host == "fizzy.bluefenix.net")
    }
}

@Suite("FizzyClient — ETag")
struct FizzyClientETagTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("getWithETag: nil etag → no If-None-Match header sent")
    func noEtagNoHeader() async throws {
        mock.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v1\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: nil, as: [FizzyBoard].self)

        let req = try #require(mock.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(response.etag == "\"v1\"")
        #expect(response.body != nil)
    }

    @Test("getWithETag: 200 returns body and new etag")
    func twoHundredReturnsBodyAndEtag() async throws {
        mock.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v2\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        let req = try #require(mock.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(response.body != nil)
        #expect(response.etag == "\"v2\"")
    }

    @Test("getWithETag: 304 returns nil body and preserves etag")
    func threeOhFourReturnsNilBody() async throws {
        mock.handler = { req in
            return (Data(), .notModified(for: req, etag: "\"v1\""))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        #expect(response.body == nil)
        #expect(response.etag == "\"v1\"")
    }
}

@Suite("FizzyClient — POST")
struct FizzyClientPostTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorPost.self)
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

    @Test("POST sends JSON body, follows Location header to GET the new resource")
    func postFollowsLocation() async throws {
        let cardData = try loadFixture("card_single")

        mock.handler = { req in
            switch req.httpMethod {
            case "POST":
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/cards")
                #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case "GET":
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
                return (cardData, .ok(for: req))
            default:
                Issue.record("unexpected method: \(req.httpMethod ?? "nil")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "First card", description: "Hello, World!", status: nil, tagIds: nil))
        let created: FizzyCard = try await client.post("/boards/B1/cards", body: payload, as: FizzyCard.self)

        #expect(created.title == "First card")
        #expect(mock.requests.count == 2)
    }

    @Test("POST surfaces 422 with parsed validation errors")
    func postValidationError() async throws {
        mock.handler = { req in
            let body = #"{"errors":{"title":["can't be blank"]}}"#.data(using: .utf8)!
            return (body, .response(for: req, status: 422))
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "", description: nil, status: nil, tagIds: nil))

        await #expect(throws: FizzyError.validation(["title: can't be blank"])) {
            let _: FizzyCard = try await client.post("/boards/B1/cards", body: payload, as: FizzyCard.self)
        }
    }

    @Test("POST 201 without a Location header throws unexpectedStatus(201)")
    func postMissingLocationHeader() async throws {
        mock.handler = { req in
            (Data(), .response(for: req, status: 201))
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "x", description: nil, status: nil, tagIds: nil))

        await #expect(throws: FizzyError.unexpectedStatus(201)) {
            let _: FizzyCard = try await client.post("/boards/B1/cards", body: payload, as: FizzyCard.self)
        }
    }
}

private final class FixtureLocatorPost {}

@Suite("FizzyClient — PUT")
struct FizzyClientPutTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocatorPut.self)
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

    @Test("PUT sends JSON body, returns updated resource")
    func putReturnsUpdated() async throws {
        let cardData = try loadFixture("card_single")

        mock.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            return (cardData, .ok(for: req))
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "Updated", description: nil, status: nil, tagIds: nil))
        let updated: FizzyCard = try await client.put("/cards/1", body: payload, as: FizzyCard.self)

        #expect(updated.id == "03f5vaeq985jlvwv3arl4srq2")
        #expect(mock.requests.count == 1)
    }
}

private final class FixtureLocatorPut {}

@Suite("FizzyClient — DELETE")
struct FizzyClientDeleteTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("DELETE succeeds on 204")
    func deleteSucceeds() async throws {
        mock.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
            return (Data(), .response(for: req, status: 204))
        }

        let client = makeClient()
        try await client.delete("/cards/1")
        #expect(mock.requests.count == 1)
    }

    @Test("DELETE surfaces 404 as FizzyError.notFound")
    func deleteNotFound() async throws {
        mock.handler = { req in
            return (Data(), .response(for: req, status: 404))
        }

        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            try await client.delete("/cards/999")
        }
    }
}

@Suite("FizzyClient — HTTP error mapping")
struct FizzyClientErrorTests {

    let mock = MockHTTPState()

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("401 → .unauthorized")
    func unauthorized() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 401)) }
        let client = makeClient()
        await #expect(throws: FizzyError.unauthorized) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("403 → .forbidden")
    func forbidden() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 403)) }
        let client = makeClient()
        await #expect(throws: FizzyError.forbidden) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("404 → .notFound")
    func notFound() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 404)) }
        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            _ = try await client.get("/boards/missing", as: FizzyBoard.self)
        }
    }

    @Test("500 → .server(500)")
    func server() async throws {
        mock.handler = { req in (Data(), .response(for: req, status: 500)) }
        let client = makeClient()
        await #expect(throws: FizzyError.server(statusCode: 500)) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("429 → .rateLimited honors Retry-After")
    func rateLimited() async throws {
        mock.handler = { req in
            (Data(), .response(for: req, status: 429, headers: ["Retry-After": "30"]))
        }
        let client = makeClient()
        await #expect(throws: FizzyError.rateLimited(retryAfter: 30)) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }
}

@Suite("FizzyClient — retry")
struct FizzyClientRetryTests {

    let mock = MockHTTPState()

    private func makeClient(clock: any Clock<Duration> & Sendable = ImmediateClock()) -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: clock
        )
    }

    @Test("transient network error retries up to 3 times then succeeds")
    func transientThenSucceeds() async throws {
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            if attempt < 3 {
                throw URLError(.networkConnectionLost)
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(attempt == 3)
    }

    @Test("transient network error gives up after 3 retries and surfaces .network")
    func transientGivesUp() async throws {
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            throw URLError(.networkConnectionLost)
        }

        let client = makeClient()
        do {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
            Issue.record("expected throw")
        } catch let error as FizzyError {
            #expect(attempt == 4)  // initial + 3 retries
            if case .network = error {
                // ok
            } else {
                Issue.record("expected .network, got \(error)")
            }
        }
    }

    @Test("4xx is not retried")
    func clientErrorNotRetried() async throws {
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            return (Data(), .response(for: req, status: 404))
        }

        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
        #expect(attempt == 1)
    }

    @Test("5xx IS retried")
    func serverErrorRetried() async throws {
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            if attempt < 3 {
                return (Data(), .response(for: req, status: 503))
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(attempt == 3)
    }

    // MARK: — 429 Retry-After backoff (task #57)

    @Test("429 with Retry-After header retries then succeeds — exactly 2 requests")
    func rateLimitedWithRetryAfterThenSucceeds() async throws {
        // First response: 429 + Retry-After: 1 → sleep(min(1s,30s)) and retry.
        // Second response: 200 → call succeeds.
        // Expected: exactly 2 requests recorded, no throw.
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            if attempt == 1 {
                return (Data(), .response(for: req, status: 429, headers: ["Retry-After": "1"]))
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(mock.requests.count == 2)
    }

    @Test("persistent 429 exhausts shared attempt budget then throws rateLimited")
    func persistentRateLimitedExhausBudget() async throws {
        // All responses are 429. The budget is 4 total (initial + 3 retries,
        // same as 5xx/URLError). After exhaustion, performWithRetry must throw
        // .rateLimited — never loop forever.
        mock.handler = { req in
            return (Data(), .response(for: req, status: 429, headers: ["Retry-After": "1"]))
        }

        let client = makeClient()
        do {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
            Issue.record("expected .rateLimited throw")
        } catch let error as FizzyError {
            // 4 total requests: attempt 0, 1, 2, 3
            #expect(mock.requests.count == 4)
            if case .rateLimited = error {
                // ok — correct error type
            } else {
                Issue.record("expected .rateLimited, got \(error)")
            }
        }
    }

    @Test("429 without Retry-After header still retries using ladder delay")
    func rateLimitedWithoutRetryAfterStillRetries() async throws {
        // Missing Retry-After → fall back to the existing ladder delay.
        // The call must still retry (not throw immediately).
        var attempt = 0
        mock.handler = { req in
            attempt += 1
            if attempt == 1 {
                // No Retry-After header
                return (Data(), .response(for: req, status: 429))
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(mock.requests.count == 2)
    }
}

@Suite("FizzyClient — Link-header pagination")
struct FizzyClientPaginationTests {

    let mock = MockHTTPState()

    private struct Item: Decodable, Equatable, Sendable {
        let id: Int
    }

    private func makeClient() -> FizzyClient {
        let session = mock.makeSession()
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "test-token",
            accountSlug: "897362094",
            urlSession: session,
            clock: ImmediateClock()
        )
    }

    @Test("follows rel=\"next\" across pages and concatenates results")
    func followsNextAcrossPages() async throws {
        mock.handler = { req in
            let url = req.url!.absoluteString
            if url.contains("page=3") {
                return (#"[{"id":5}]"#.data(using: .utf8)!, .ok(for: req))
            } else if url.contains("page=2") {
                let headers = ["Link": "<https://fizzy.bluefenix.net/897362094/cards?page=3>; rel=\"next\""]
                return (#"[{"id":3},{"id":4}]"#.data(using: .utf8)!, .ok(for: req, headers: headers))
            } else {
                let headers = ["Link": "<https://fizzy.bluefenix.net/897362094/cards?page=2>; rel=\"next\""]
                return (#"[{"id":1},{"id":2}]"#.data(using: .utf8)!, .ok(for: req, headers: headers))
            }
        }

        let items = try await makeClient().getAllPages("/cards", as: [Item].self)
        #expect(items == [Item(id: 1), Item(id: 2), Item(id: 3), Item(id: 4), Item(id: 5)])
        #expect(mock.requests.count == 3)
        // Pages 2+ are requested at the exact URL from the Link header.
        #expect(mock.requests[1].url?.absoluteString
            == "https://fizzy.bluefenix.net/897362094/cards?page=2")
        // Auth carries across page follows.
        #expect(mock.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("lowercase `link:` header (doc wire shape) is honored on same-origin follows")
    func docWireShapeLinkHeader() async throws {
        // fizzy docs/api/README.md ("Pagination") prints the header lowercase:
        //   < link: <http://app.fizzy.localhost:3006/686465299/cards?page=2>; rel="next"
        mock.handler = { req in
            if req.url!.absoluteString.contains("page=2") {
                return (#"[{"id":2}]"#.data(using: .utf8)!, .ok(for: req))
            }
            let headers = ["link": "<https://fizzy.bluefenix.net/897362094/cards?page=2>; rel=\"next\""]
            return (#"[{"id":1}]"#.data(using: .utf8)!, .ok(for: req, headers: headers))
        }

        let items = try await makeClient().getAllPages("/cards", as: [Item].self)
        #expect(items == [Item(id: 1), Item(id: 2)])
        #expect(mock.requests[1].url?.absoluteString
            == "https://fizzy.bluefenix.net/897362094/cards?page=2")
    }

    @Test("cross-origin rel=\"next\" is NOT followed — Bearer token stays on baseURL's origin")
    func crossOriginNextIsRejected() async throws {
        // Verbatim header from fizzy docs/api/README.md ("Pagination") — its host
        // (app.fizzy.localhost:3006) differs from this client's baseURL, exactly
        // the shape a hostile/misconfigured server could use to exfiltrate the
        // Authorization header. Pagination must stop, not follow.
        mock.handler = { req in
            let headers = ["link": "<http://app.fizzy.localhost:3006/686465299/cards?page=2>; rel=\"next\""]
            return (#"[{"id":1}]"#.data(using: .utf8)!, .ok(for: req, headers: headers))
        }

        let items = try await makeClient().getAllPages("/cards", as: [Item].self)
        #expect(items == [Item(id: 1)])
        #expect(mock.requests.count == 1)
    }

    @Test("single page without Link header returns just that page")
    func singlePageNoLink() async throws {
        mock.handler = { req in
            (#"[{"id":1}]"#.data(using: .utf8)!, .ok(for: req))
        }

        let items = try await makeClient().getAllPages("/cards", as: [Item].self)
        #expect(items == [Item(id: 1)])
        #expect(mock.requests.count == 1)
    }

    @Test("Link header with only rel=\"prev\" does not loop")
    func linkWithoutNextStops() async throws {
        mock.handler = { req in
            let headers = ["Link": "<https://fizzy.bluefenix.net/897362094/cards?page=1>; rel=\"prev\""]
            return (#"[{"id":9}]"#.data(using: .utf8)!, .ok(for: req, headers: headers))
        }

        let items = try await makeClient().getAllPages("/cards", as: [Item].self)
        #expect(items == [Item(id: 9)])
        #expect(mock.requests.count == 1)
    }
}
