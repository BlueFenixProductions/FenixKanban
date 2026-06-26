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


/// Per-session state for `MockURLProtocol` (issue #10). Each suite creates
/// its own instance and builds sessions from `makeSession()`; the protocol
/// finds the right instance through a token header the session injects into
/// every request. No cross-suite shared state — suites parallelize freely.
/// Swift Testing instantiates the suite struct per test, so a suite-stored
/// instance is per-test automatically (no reset needed).
///
/// Per-suite setup:
///
///     let mock = MockHTTPState()
///     let session = mock.makeSession()
///     mock.handler = { req in (Data("hi".utf8), .ok(for: req)) }
final class MockHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    private var _delayedHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    private var _requests: [URLRequest] = []

    fileprivate let token = UUID().uuidString

    init() {
        MockURLProtocol.register(self)
    }

    /// Test sets this before issuing requests.
    var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    /// Async variant checked before `handler` — lets a test gate a response
    /// on a signal it controls (e.g. hold one request in flight while a
    /// second completes).
    var delayedHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))? {
        get { lock.lock(); defer { lock.unlock() }; return _delayedHandler }
        set { lock.lock(); defer { lock.unlock() }; _delayedHandler = newValue }
    }

    /// Record of every request the SUT issued through this state's
    /// sessions, in order.
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    fileprivate func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }; _requests.append(request)
    }

    /// Clears all recorded requests. Use in tests to isolate a specific
    /// code path after setup traffic (e.g. after `model.load()` to verify
    /// that a subsequent action issues no network requests).
    func resetRequests() {
        lock.lock(); defer { lock.unlock() }; _requests.removeAll()
    }

    /// Builds a session whose requests resolve back to this state instance.
    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [MockURLProtocol.stateHeader: token]
        return URLSession(configuration: config)
    }
}

/// In-process URL protocol that intercepts URLSession requests. All mutable
/// state lives on `MockHTTPState` instances; the only static here is the
/// token→state registry — lock-protected, write-once per state, and keyed
/// by UUID, so concurrent suites cannot interfere (the issue-#10 race was
/// the unsynchronized shared handler/requests, not statics per se). Entries
/// are never pruned: bounded by the number of suite instances in one short-
/// lived test process.
final class MockURLProtocol: URLProtocol {
    static let stateHeader = "X-FK-Mock-State"

    private static let registryLock = NSLock()
    private static var registry: [String: MockHTTPState] = [:]

    static func register(_ state: MockHTTPState) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[state.token] = state
    }

    private static func state(for request: URLRequest) -> MockHTTPState? {
        guard let token = request.value(forHTTPHeaderField: stateHeader) else { return nil }
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[token]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.state(for: request) else {
            // Session not built via MockHTTPState.makeSession() — fail the
            // request loudly rather than let it escape to the network.
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        state.record(request)
        if let delayedHandler = state.delayedHandler {
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
        guard let handler = state.handler else {
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
