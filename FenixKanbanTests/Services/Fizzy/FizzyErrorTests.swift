import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyError")
struct FizzyErrorTests {

    @Test("status code → error mapping")
    func statusMapping() {
        #expect(FizzyError(httpStatus: 401, body: nil) == .unauthorized)
        #expect(FizzyError(httpStatus: 403, body: nil) == .forbidden)
        #expect(FizzyError(httpStatus: 404, body: nil) == .notFound)
        #expect(FizzyError(httpStatus: 422, body: nil) == .validation([]))
        #expect(FizzyError(httpStatus: 500, body: nil) == .server(statusCode: 500))
        #expect(FizzyError(httpStatus: 503, body: nil) == .server(statusCode: 503))
        #expect(FizzyError(httpStatus: 418, body: nil) == .unexpectedStatus(418))
    }

    @Test("422 with field errors parses the body")
    func validationParsesBody() throws {
        let json = """
        { "errors": { "title": ["can't be blank"], "tags": ["max 10 allowed"] } }
        """.data(using: .utf8)!

        let err = FizzyError(httpStatus: 422, body: json)
        if case .validation(let messages) = err {
            #expect(Set(messages) == Set(["title: can't be blank", "tags: max 10 allowed"]))
        } else {
            Issue.record("expected .validation, got \(err)")
        }
    }

    @Test("429 retryAfter parses from header value seconds")
    func rateLimitedHeader() {
        #expect(FizzyError(httpStatus: 429, retryAfter: "60") == .rateLimited(retryAfter: 60))
        #expect(FizzyError(httpStatus: 429, retryAfter: "0.5") == .rateLimited(retryAfter: 0.5))
        #expect(FizzyError(httpStatus: 429, retryAfter: nil) == .rateLimited(retryAfter: 60))
        #expect(FizzyError(httpStatus: 429, retryAfter: "not-a-number") == .rateLimited(retryAfter: 60))
    }

    @Test("Equatable")
    func equatable() {
        #expect(FizzyError.unauthorized == FizzyError.unauthorized)
        #expect(FizzyError.unauthorized != FizzyError.forbidden)
        #expect(FizzyError.server(statusCode: 500) == FizzyError.server(statusCode: 500))
        #expect(FizzyError.server(statusCode: 500) != FizzyError.server(statusCode: 502))
        #expect(FizzyError.validation(["a"]) == FizzyError.validation(["a"]))
        #expect(FizzyError.validation(["a"]) != FizzyError.validation(["b"]))
    }
}
