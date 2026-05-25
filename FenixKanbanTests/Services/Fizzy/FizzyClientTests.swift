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
