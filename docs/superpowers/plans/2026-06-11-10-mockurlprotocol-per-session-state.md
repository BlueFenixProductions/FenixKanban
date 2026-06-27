# Issue #10 — MockURLProtocol Per-Session State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MockURLProtocol`'s static `handler`/`delayedHandler`/`requests` with a per-session state object so HTTP-mocking suites are race-free, then enable test parallelization (scheme `parallelizable = "YES"`) and drop the `.serialized` modifiers from the pure-HTTP FizzyClient suites.

**Architecture:** `URLProtocol` is registered by *type*, so per-session state can't be injected directly. The standard fix: a `MockHTTPState` instance per suite, whose `makeSession()` builds the `URLSession` and injects a UUID token via `httpAdditionalHeaders` (the URL loading system merges session additional headers into the request the protocol sees). The protocol resolves its state from the token through a lock-protected registry — the registry is static, but write-once per state, token-keyed, and lock-protected, so no cross-suite interference is possible. Swift Testing instantiates the suite struct per test, so state is naturally per-test; all 97 `MockURLProtocol.reset()` calls become dead and are deleted.

**Current-state notes (differs from the issue text):** `FizzyClientSerialContainer` (commit `df4b24c`) no longer exists — the bandaid's present shape is per-suite `.serialized` on every suite PLUS scheme-level `parallelizable = "NO"`, which makes the whole bundle serial. That scheme flag is what actually protects the statics today. Fixtures elsewhere are already parallel-safe (UUID-suffixed pairing-store temp files, unique UserDefaults suite names, per-suite in-memory PersistenceControllers over the read-only `sharedModel`).

**Tech Stack:** Swift 5.9, Swift Testing, URLProtocol/URLSession, NSLock (`@unchecked Sendable`, `TagPushCallCounter` precedent).

**Migration inventory:** 190 × `MockURLProtocol.handler`, 57 × `.requests`, 5 × `.delayedHandler`, 97 × `.reset()`, 37 session-construction sites across 11 consumer files.

---

### Task 1: RED — per-session isolation test

**Files:**
- Create: `FenixKanbanTests/Services/Fizzy/MockURLProtocolIsolationTests.swift`

- [ ] **Step 1: Write the failing test** (deliberately NOT `.serialized` — concurrency is the point)

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("MockURLProtocol per-session isolation (issue #10)")
struct MockURLProtocolIsolationTests {
    @Test("two concurrent sessions keep separate handlers and request logs")
    func twoSessionsStayIsolated() async throws {
        let mockA = MockHTTPState()
        let mockB = MockHTTPState()
        mockA.handler = { req in (Data("A".utf8), .ok(for: req)) }
        mockB.handler = { req in (Data("B".utf8), .ok(for: req)) }
        let sessionA = mockA.makeSession()
        let sessionB = mockB.makeSession()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let (data, _) = try await sessionA.data(from: URL(string: "https://a.test/\(i)")!)
                    #expect(String(decoding: data, as: UTF8.self) == "A")
                }
                group.addTask {
                    let (data, _) = try await sessionB.data(from: URL(string: "https://b.test/\(i)")!)
                    #expect(String(decoding: data, as: UTF8.self) == "B")
                }
            }
            try await group.waitForAll()
        }

        #expect(mockA.requests.count == 20)
        #expect(mockB.requests.count == 20)
        #expect(mockA.requests.allSatisfy { $0.url?.host == "a.test" })
        #expect(mockB.requests.allSatisfy { $0.url?.host == "b.test" })
    }
}
```

- [ ] **Step 2: Verify RED** — build fails: `cannot find 'MockHTTPState' in scope` (API-absent RED, #42 precedent). The static design cannot express two simultaneous handlers.

- [ ] **Step 3: Commit**

```bash
git add FenixKanbanTests/Services/Fizzy/MockURLProtocolIsolationTests.swift
git commit -m "test(10): RED — two concurrent mock sessions must keep isolated handler/request state"
```

### Task 2: GREEN — MockHTTPState + token-header resolution

**Files:**
- Modify: `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift` (replace the static-state protocol; `ImmediateClock` + `HTTPURLResponse` helpers stay)

- [ ] **Step 1: Implement.** Replace the `MockURLProtocol` class with:

```swift
/// Per-session state for `MockURLProtocol` (issue #10). Each suite creates
/// its own instance and builds sessions from `makeSession()`; the protocol
/// finds the right instance through a token header the session injects into
/// every request. No cross-suite shared state — suites parallelize freely.
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
```

- [ ] **Step 2: Run ONLY the isolation test.** It empirically validates that `httpAdditionalHeaders` reach the protocol BEFORE the 380-reference migration. If the token doesn't propagate, STOP and redesign (fallback: dynamic subclass registry) — do not start Task 3.

Run: `xcodebuild test ... -only-testing:FenixKanbanTests/MockURLProtocolIsolationTests` (build of other files will fail at this point — they still reference statics — so temporarily expect compile errors and fix order: Task 3 migrates consumers; alternatively run after Task 3 if the target won't build piecemeal. Practical order: implement Task 2 + migrate (Task 3) in one build cycle, but verify the isolation test FIRST in the run order.)

- [ ] **Step 3: Commit** (may fold into Task 3's commit if the target only builds after migration)

### Task 3: Migrate the 11 consumer files

**Files (all Modify):** `FizzyClientTests.swift`, `FizzyClientDirectoryTests.swift`, `FizzyClientCommentsTests.swift`, `FizzyClientBoardsTests.swift`, `FizzyClientCardActionsTests.swift`, `FizzySyncEngineTests.swift`, `FizzySyncEngineAdoptionResilienceTests.swift`, `FizzySyncEngineBoardIsolationTests.swift`, `FizzySyncProviderTests.swift`, `CardDetailViewModelTests.swift`, `CardStepsViewModelTests.swift`, `BoardViewModelGoldenTests.swift`

Per file, in this order:

- [ ] **Step 1: mechanical sed** (then hand-fix what it can't):

```bash
# 1. accessor renames
sed -i '' 's/MockURLProtocol\.handler/mock.handler/g; s/MockURLProtocol\.delayedHandler/mock.delayedHandler/g; s/MockURLProtocol\.requests/mock.requests/g' <file>
# 2. delete whole-line reset calls (per-test suite instances make them dead)
sed -i '' '/^[[:space:]]*MockURLProtocol\.reset()$/d' <file>
```

- [ ] **Step 2: hand edits per suite:**
  - Add `let mock = MockHTTPState()` property to every suite struct that now references `mock`.
  - Replace each session construction block
    ```swift
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    ... URLSession(configuration: config)
    ```
    with `mock.makeSession()` passed to the client/SUT.
  - `init() { MockURLProtocol.reset() }` single-line forms → drop the init if otherwise empty.
  - Inspect any assertion on full header sets (the token header now rides every request) — adjust only if one exists.

- [ ] **Step 3: Remove `.serialized` from the FizzyClient suites only** (`FizzyClientTests.swift` ×7 sub-suites, `FizzyClientDirectoryTests`, `FizzyClientCommentsTests`, `FizzyClientBoardsTests`, `FizzyClientCardActionsTests`) — pure HTTP, no Core Data. Other suites keep `.serialized` (Core Data / actor reasons are out of #10's scope).

- [ ] **Step 4: Build + run the whole FenixKanbanTests bundle** (still serial at scheme level). Expected: all green incl. the isolation test.

- [ ] **Step 5: Commit**

```bash
git add FenixKanbanTests
git commit -m "refactor(10): per-session MockHTTPState — statics gone, FizzyClient suites de-serialized"
```

### Task 4: Enable parallel testing

- [ ] **Step 1:** `FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme`: `parallelizable = "NO"` → `parallelizable = "YES"`.
- [ ] **Step 2:** Full suite on the pinned sim **twice** (flake confidence). Expected: green both times, wall-clock at or below the serial run.
- [ ] **Step 3:** macOS build (`CODE_SIGNING_ALLOWED=NO`): `BUILD SUCCEEDED`, zero warnings.
- [ ] **Step 4: Commit**

```bash
git add FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
git commit -m "test(10): enable parallel test execution — per-session mock state makes it safe"
```

### Task 5: Bookkeeping

- [ ] Status log entry #46 in `TDD_IMPLEMENTATION_STATUS.md` (note the bandaid's real present shape: container already gone, scheme-level serialization was the protector).
- [ ] Commit docs + this plan; push branch; open PR **stacked on `claude/recursing-wing-107418`** so PR #25 stays independently mergeable. `Refs #10` + "closes when merged" comment is captain's call.
