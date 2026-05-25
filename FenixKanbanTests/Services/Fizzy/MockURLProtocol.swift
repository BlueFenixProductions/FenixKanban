import Foundation

/// In-process URL protocol that intercepts URLSession requests. Tests register
/// a handler closure that returns either a `(Data, HTTPURLResponse)` or throws.
///
/// Per-test setup:
///
///     let config = URLSessionConfiguration.ephemeral
///     config.protocolClasses = [MockURLProtocol.self]
///     let session = URLSession(configuration: config)
///     MockURLProtocol.handler = { req in (Data("hi".utf8), .ok(for: req)) }
final class MockURLProtocol: URLProtocol {

    /// Test sets this before issuing requests; cleared in tearDown.
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    /// Record of every request the SUT issued during the test, in order.
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension HTTPURLResponse {
    static func ok(for request: URLRequest, headers: [String: String] = [:]) -> HTTPURLResponse {
        response(for: request, status: 200, headers: headers)
    }

    static func notModified(for request: URLRequest, etag: String) -> HTTPURLResponse {
        response(for: request, status: 304, headers: ["ETag": etag])
    }

    static func response(for request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
