import Foundation

// MARK: - ImmediateClock

/// A `Clock` that suspends for zero wall-clock time. Conforming to
/// `Clock<Duration>` lets it substitute for `ContinuousClock` in unit tests so
/// retry backoff delays don't slow down the test suite.
struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Self {
            Instant(offset: offset + duration)
        }

        func duration(to other: Self) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // No-op — return immediately so tests don't wait for real backoff delays.
    }
}


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

    /// Async variant checked before `handler` — lets a test gate a response
    /// on a signal it controls (e.g. hold one request in flight while a
    /// second completes). Cleared by `reset()`.
    static var delayedHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))?

    /// Record of every request the SUT issued during the test, in order.
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        delayedHandler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let delayedHandler = Self.delayedHandler {
            Task {
                do {
                    let (data, response) = try await delayedHandler(self.request)
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: data)
                    self.client?.urlProtocolDidFinishLoading(self)
                } catch {
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
            return
        }
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
