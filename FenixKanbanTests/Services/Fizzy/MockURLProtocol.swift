import Foundation
import Testing

// MARK: - MockURLProtocolSerial trait

/// A `SuiteTrait` / `TestTrait` that serializes every test annotated with
/// it against a single process-wide lock. Apply to ANY suite that reads or
/// writes `MockURLProtocol.handler` / `requests` (directly or transitively
/// via `FizzyClient` / `FizzySyncEngine` / `FizzySyncProvider`). Without
/// this, CI's swift-testing parallelism races setup against in-flight
/// requests and produces `URLError(.badURL)` or stale-handler crosstalk.
///
/// This is a bandaid for the static-state design of `MockURLProtocol`;
/// see issue #10 for the proper instance-scoped refactor.
struct MockURLProtocolSerial: SuiteTrait, TestTrait, TestScoping {

    // NSLock is non-recursive, which is fine here: each test enters the
    // scope exactly once (no nested mock-using tests).
    nonisolated(unsafe) static let lock = NSLock()

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing: @Sendable () async throws -> Void
    ) async throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try await performing()
    }
}

extension Trait where Self == MockURLProtocolSerial {
    /// Serialize this suite/test against all other `MockURLProtocol`-using
    /// suites via a process-wide lock. See `MockURLProtocolSerial`.
    static var mockURLProtocolSerial: Self { MockURLProtocolSerial() }
}

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
