import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyClient — auth + URL construction", .serialized)
struct FizzyClientAuthTests {

    init() {
        MockURLProtocol.reset()
    }

    private func makeClient(token: String = "test-token", slug: String = "897362094") -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: token,
            accountSlug: slug,
            urlSession: session
        )
    }

    @Test("GET attaches Bearer header + interpolates :account_slug into path")
    func authAndSlug() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"abc\""]))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/boards")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("paths starting with /my/ are NOT account-scoped (Fizzy convention)")
    func myPathsBypassSlug() async throws {
        MockURLProtocol.handler = { req in
            let body = #"{"accounts":[]}"#.data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/my/identity", as: FizzyIdentity.self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/my/identity")
    }

    @Test("paths with /my prefix but no trailing slash DO get scoped")
    func myPrefixWithoutSlashIsScoped() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/myth-busters", as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/myth-busters")
    }
}

@Suite("FizzyClient — ETag", .serialized)
struct FizzyClientETagTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("getWithETag: nil etag → no If-None-Match header sent")
    func noEtagNoHeader() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v1\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: nil, as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(response.etag == "\"v1\"")
        #expect(response.body != nil)
    }

    @Test("getWithETag: 200 returns body and new etag")
    func twoHundredReturnsBodyAndEtag() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v2\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(response.body != nil)
        #expect(response.etag == "\"v2\"")
    }

    @Test("getWithETag: 304 returns nil body and preserves etag")
    func threeOhFourReturnsNilBody() async throws {
        MockURLProtocol.handler = { req in
            return (Data(), .notModified(for: req, etag: "\"v1\""))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        #expect(response.body == nil)
        #expect(response.etag == "\"v1\"")
    }
}

@Suite("FizzyClient — POST", .serialized)
struct FizzyClientPostTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
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

        MockURLProtocol.handler = { req in
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
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test("POST surfaces 422 with parsed validation errors")
    func postValidationError() async throws {
        MockURLProtocol.handler = { req in
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
        MockURLProtocol.handler = { req in
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
