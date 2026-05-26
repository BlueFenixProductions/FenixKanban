# Fizzy Integration — Phase 5: UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `FizzySyncEngine` (Phase 4a/4b) into the app via `FizzySyncProvider` (`BoardSyncProvider` conformance) and three new SwiftUI surfaces (`FizzyAuthVerifyView`, `FizzyAuthPairView`, `FizzyAuthStatusView`) hosted by a phase-switching parent `FizzyAuthView`. Users can paste a Fizzy access token, verify, pair a local board with a Fizzy board, sync manually, and re-auth inline when sync returns 401.

**Architecture:** `FizzySyncProvider` is constructed at app launch with the production `FizzyAuthState` / `FizzyBoardMapping` and registered in `PluginRegistry.shared`. `SyncSettingsView` (existing) gets a status badge and pushes `FizzyAuthView` on tap. `FizzyAuthView` is a thin parent that computes `phase` from `authState + mapping` and switches between three sub-views (Verify / Pair / Status), each owning its own transient `@State`. A `forceVerify` override on the parent lets the Status view's "Re-enter Token" CTA short-circuit the phase computation when the engine clears `authState` mid-session on a 401.

**Tech Stack:** Swift 6 async/await, SwiftUI (`@State`, `NavigationLink`, `Form`, `.fileExporter`-free), Swift Testing for `@MainActor` provider tests, MockURLProtocol for HTTP fakes (existing test utility).

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md` (§ Phase 5 — UI)

**Out of scope for Phase 5** (deferred):

- Polling timer (5-minute foreground poll while `scenePhase == .active`) → **Phase 6**.
- `CardView` cloud badges showing per-card sync state → **Phase 6**.
- Phase 4c reviewer follow-ups (BackupExporter off-main-actor refactor, BackupDocument: Sendable annotation, Data Settings section split, schema-name constant extraction) → Phase 6 polish pass, or a separate Phase 4d if you want them sooner.
- Auto-registration with system Shortcuts for "Sync now" → deferred pending Phase 6's AppIntents work.

---

## File Structure

**Created:**
- `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` — `BoardSyncProvider` conformance + factory.
- `FenixKanban/Features/Sync/Fizzy/FizzyAuthPhase.swift` — phase enum.
- `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift` — phase-switching parent.
- `FenixKanban/Features/Sync/Fizzy/FizzyAuthVerifyView.swift` — token paste + verify.
- `FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift` — three pickers + destructive UX + backup banner.
- `FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift` — status hero + 401 banner + Sync Now + Sign Out.
- `FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift` — 6 unit tests.

**Modified:**
- `FenixKanban/Core/Services/Fizzy/FizzyError.swift` — add `.requiresInteractiveAuth` case.
- `FenixKanban/Features/Sync/SyncSettingsView.swift` — status badge, navigation push, remove empty state.
- `FenixKanban/FenixKanbanApp.swift` — register `FizzySyncProvider` in `init()`.
- `TDD_IMPLEMENTATION_STATUS.md` — append Phase 5 entry.

---

## Task 1: Add `FizzyError.requiresInteractiveAuth`

The signal `FizzySyncProvider.authenticate()` throws to tell the UI "open `FizzyAuthView` for the user to paste a token."

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyError.swift`

- [ ] **Step 1: Add the case**

In `FenixKanban/Core/Services/Fizzy/FizzyError.swift`, find the enum declaration. Add `requiresInteractiveAuth` as a new case immediately after `unauthorized`:

Before:
```swift
enum FizzyError: Error, Equatable {
    case unauthorized              // 401 — token revoked/expired
    case forbidden                 // 403 — token lacks scope
    case notFound                  // 404 — resource gone or never existed
```

After:
```swift
enum FizzyError: Error, Equatable {
    case unauthorized              // 401 — token revoked/expired
    case requiresInteractiveAuth   // signal: caller must open FizzyAuthView for token paste
    case forbidden                 // 403 — token lacks scope
    case notFound                  // 404 — resource gone or never existed
```

No init logic changes — `requiresInteractiveAuth` isn't an HTTP status, it's an internal protocol-bridging signal.

- [ ] **Step 2: Verify build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyError.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyError.requiresInteractiveAuth case

Signals to BoardSyncProvider's UI that the caller must open
FizzyAuthView so the user can paste a token. Not an HTTP status —
purely a protocol-bridging signal between FizzySyncProvider
(non-interactive API) and the UI layer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `FizzySyncProvider` (conformance + 6 tests)

The bridge between `FizzySyncEngine` and the existing `BoardSyncProvider` plugin pattern.

**Files:**
- Create: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift`
- Create: `FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncProvider", .serialized)
@MainActor
struct FizzySyncProviderTests {

    /// Builds an in-memory persistence + isolated auth/mapping suite
    /// + MockURLProtocol-backed FizzyClient. Returns a configured provider
    /// for the test to exercise.
    private struct Harness {
        let persistence: PersistenceController
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let suiteName: String
        let provider: FizzySyncProvider

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)

            let prefix = "test.fizzy.provider.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)

            suiteName = "test.fizzy.provider.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)

            provider = FizzySyncProvider(
                authState: authState,
                mapping: mapping,
                persistence: persistence,
                urlSession: session,
                clock: ImmediateClock()
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("providerName is 'Fizzy'")
    func providerNameMatchesSpec() {
        let h = Harness(); defer { h.tearDown() }
        #expect(h.provider.providerName == "Fizzy")
    }

    @Test("isAuthenticated mirrors authState.isConfigured")
    func isAuthenticatedMirrorsAuthState() {
        let h = Harness(); defer { h.tearDown() }
        #expect(h.provider.isAuthenticated == false)

        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")
        #expect(h.provider.isAuthenticated == true)

        h.authState.clear()
        #expect(h.provider.isAuthenticated == false)
    }

    @Test("authenticate() throws requiresInteractiveAuth — UI must open FizzyAuthView")
    func authenticateThrowsInteractiveSignal() async {
        let h = Harness(); defer { h.tearDown() }
        do {
            try await h.provider.authenticate()
            Issue.record("expected authenticate() to throw")
        } catch let error as FizzyError {
            #expect(error == .requiresInteractiveAuth)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("signOut clears authState and mapping but keeps local Cards")
    func signOutClearsAuthAndMappingNoCards() async throws {
        let h = Harness(); defer { h.tearDown() }

        // Build a paired board with cards on both the paired and a non-paired board.
        let boardRepo = BoardRepository(context: h.persistence.viewContext)
        let cardRepo = CardRepository(context: h.persistence.viewContext)
        let paired = boardRepo.createBoard(name: "Paired")
        let pairedCol = boardRepo.createColumn(in: paired, name: "C")
        _ = cardRepo.createCard(in: pairedCol, title: "kept-1")
        _ = cardRepo.createCard(in: pairedCol, title: "kept-2")

        let other = boardRepo.createBoard(name: "Other")
        let otherCol = boardRepo.createColumn(in: other, name: "C")
        _ = cardRepo.createCard(in: otherCol, title: "kept-3")

        try h.persistence.viewContext.save()

        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")
        let mapping = FizzyBoardMapping(defaults: h.mappingDefaults)
        mapping.setPairing(localBoardID: paired.id!, fizzyBoardID: "FB1")
        mapping.setLastSync(.now)

        try await h.provider.signOut()

        #expect(h.authState.accessToken == nil)
        #expect(h.authState.accountSlug == nil)
        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)

        // Cards on both boards still present.
        let cardRequest: NSFetchRequest<Card> = Card.fetchRequest()
        let allCards = try h.persistence.viewContext.fetch(cardRequest)
        #expect(allCards.count == 3)
    }

    @Test("fetchRemoteBoards maps FizzyBoard JSON to RemoteBoard")
    func fetchRemoteBoardsMapsDTOs() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok"); h.authState.setAccountSlug("ACCT")

        let json = """
        [
          {"id":"FB1","name":"Public Roadmap","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":"https://fizzy.bluefenix.net/ACCT/boards/FB1","creator":{"id":"U1","name":"Chris","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}},
          {"id":"FB2","name":"Private","all_access":false,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":3,"url":null,"creator":{"id":"U1","name":"Chris","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
        ]
        """
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/boards"):
                return (json.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let remoteBoards = try await h.provider.fetchRemoteBoards()

        #expect(remoteBoards.count == 2)
        #expect(remoteBoards[0].id == "FB1")
        #expect(remoteBoards[0].name == "Public Roadmap")
        #expect(remoteBoards[0].provider == "Fizzy")
        #expect(remoteBoards[1].id == "FB2")
        #expect(remoteBoards[1].name == "Private")
    }

    @Test("sync() translates FizzySyncResult counts to public SyncResult")
    func syncTranslatesFizzySyncResultToPublicSyncResult() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok"); h.authState.setAccountSlug("ACCT")

        // Pair a local board so sync() actually runs.
        let boardRepo = BoardRepository(context: h.persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        _ = boardRepo.createColumn(in: board, name: "C")
        try h.persistence.viewContext.save()
        let mapping = FizzyBoardMapping(defaults: h.mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        // Steady-state sync fetches empty columns/cards — engine returns zero changes.
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.provider.sync(boardId: board.id!, remoteProjectId: "FB1")

        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)
    }
}
```

- [ ] **Step 2: Run failing tests**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncProviderTests test 2>&1 | tail -10
```

Expected: build fails — `FizzySyncProvider` not defined.

- [ ] **Step 3: Implement FizzySyncProvider**

Create `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift`:

```swift
import Foundation
import CoreData

/// Bridges `FizzySyncEngine` to the app's generic `BoardSyncProvider` plugin
/// protocol. Constructed once at app launch in `FenixKanbanApp.init()` and
/// registered in `PluginRegistry.shared`. Holds Phase 2's `FizzyAuthState`
/// and `FizzyBoardMapping` for the lifetime of the app process; rebuilds
/// `FizzyClient` + `FizzySyncEngine` on demand so changes to `authState`
/// (token paste, slug refresh) are picked up without re-registration.
///
/// Phase 5 only handles the manual entry points (`fetchRemoteBoards`,
/// `sync`). The foreground polling timer lands in Phase 6.
@MainActor
final class FizzySyncProvider: BoardSyncProvider {

    let providerName: String = "Fizzy"
    let iconName: String = "bolt.circle.fill"

    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let persistence: PersistenceController
    private let urlSession: URLSession
    private let clock: any Clock<Duration>

    init(
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        persistence: PersistenceController,
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.authState = authState
        self.mapping = mapping
        self.persistence = persistence
        self.urlSession = urlSession
        self.clock = clock
    }

    /// `true` when both token and slug are present in the Keychain.
    /// The UI uses this to choose between the verify view and the
    /// paired/unpaired views.
    var isAuthenticated: Bool {
        authState.isConfigured
    }

    /// Throws `FizzyError.requiresInteractiveAuth` — the BoardSyncProvider
    /// generic auth flow doesn't fit Fizzy's "paste a token + verify"
    /// shape. The UI uses this signal to push `FizzyAuthView` instead.
    func authenticate() async throws {
        throw FizzyError.requiresInteractiveAuth
    }

    /// Clears Keychain entries and the singleton pairing. **Does NOT
    /// touch local `Card` data** — re-pairing to the same Fizzy board
    /// later will re-bind cards via the engine's orphan-claim logic.
    func signOut() async throws {
        authState.clear()
        mapping.clear()
    }

    /// `GET /:account/boards` — maps the Fizzy DTOs to the generic
    /// `RemoteBoard` shape the picker UI consumes.
    func fetchRemoteBoards() async throws -> [RemoteBoard] {
        guard let client = makeClient() else {
            throw FizzyError.requiresInteractiveAuth
        }
        let boards = try await client.get("/boards", as: [FizzyBoard].self)
        return boards.map { b in
            RemoteBoard(
                id: b.id,
                name: b.name,
                description: nil,
                url: b.url,
                provider: providerName
            )
        }
    }

    /// Runs the steady-state sync cycle via `FizzySyncEngine.sync()` and
    /// translates the engine's `FizzySyncResult` into the generic
    /// `SyncResult` returned by `BoardSyncProvider`. The `boardId` and
    /// `remoteProjectId` parameters are required by the protocol but
    /// Phase 5's engine pairs on a singleton basis — pairing must already
    /// match these IDs (the provider doesn't currently switch pairings
    /// per-call). They're accepted but unused.
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult {
        guard let engine = makeEngine() else {
            throw FizzyError.requiresInteractiveAuth
        }
        let result = try await engine.sync()
        return SyncResult(
            itemsCreated: result.itemsCreated,
            itemsUpdated: result.itemsUpdated,
            itemsDeleted: result.itemsDeleted,
            errors: result.errors,
            syncDate: .now
        )
    }

    /// Returns `mapping.lastSyncAt` (singleton — `boardId` is ignored
    /// since Phase 5 pairs at most one local board).
    func lastSyncDate(for boardId: UUID) -> Date? {
        mapping.lastSyncAt
    }

    // MARK: - Internal accessors (used by FizzyAuthView sub-views)

    /// Exposed so `FizzyAuthView` and its sub-views can drive verify / pair
    /// flows without each constructing their own auth/mapping handles.
    var authStateRef: FizzyAuthState { authState }
    var mappingRef: FizzyBoardMapping { mapping }
    var persistenceRef: PersistenceController { persistence }

    /// Builds a `FizzyClient` using a caller-supplied token + slug.
    /// Used by the verify view when the slug isn't known yet (the verify
    /// view passes an empty slug; `/my/identity` paths skip slug
    /// interpolation).
    func makeClient(accessToken: String, accountSlug: String) -> FizzyClient {
        FizzyClient(
            baseURL: authState.baseURL,
            accessToken: accessToken,
            accountSlug: accountSlug,
            urlSession: urlSession,
            clock: clock
        )
    }

    /// Builds a `FizzyClient` using the currently-stored credentials.
    /// Returns `nil` when `authState.isConfigured == false`.
    func makeClient() -> FizzyClient? {
        guard let token = authState.accessToken, let slug = authState.accountSlug else {
            return nil
        }
        return makeClient(accessToken: token, accountSlug: slug)
    }

    /// Builds a `FizzySyncEngine` wired to the current auth + mapping +
    /// persistence. Returns `nil` when unauthenticated.
    func makeEngine() -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext
        )
    }
}
```

- [ ] **Step 4: Run + verify all 6 tests pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncProviderTests test 2>&1 | tail -10
```

Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzySyncProvider — BoardSyncProvider conformance

Bridges FizzySyncEngine to the app's generic BoardSyncProvider
plugin protocol. Holds authState/mapping/persistence for the
app lifetime; rebuilds FizzyClient + engine on demand so token
changes are picked up without re-registration.

- providerName "Fizzy", isAuthenticated mirrors authState.isConfigured
- authenticate() throws requiresInteractiveAuth — UI presents FizzyAuthView
- signOut clears authState + mapping; Cards are intentionally untouched
- fetchRemoteBoards maps FizzyBoard[] → RemoteBoard[]
- sync(_:_:) calls engine.sync(), translates FizzySyncResult → SyncResult

6 tests cover all protocol surfaces.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `FizzyAuthPhase` + parent `FizzyAuthView`

The phase enum drives sub-view selection; the parent owns shared deps and the `forceVerify` override.

**Files:**
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyAuthPhase.swift`
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift`

No tests for this task — the sub-views are SwiftUI surfaces exercised via UAT. The phase enum is exercised indirectly by the parent's view body.

- [ ] **Step 1: Create the phase enum**

Create `FenixKanban/Features/Sync/Fizzy/FizzyAuthPhase.swift`:

```swift
import Foundation

/// The four states `FizzyAuthView` can be in, computed from
/// `FizzyAuthState.isConfigured` + `FizzyBoardMapping.isPaired`.
///
/// - `.unconfigured`: no token in Keychain → show verify view.
/// - `.unpaired`: token + slug set but no board pairing → show pair view.
/// - `.paired`: fully configured → show status view.
/// - `.pairedNoToken`: pairing persists but token was cleared mid-session
///   by a 401 in `FizzySyncEngine.sync()`. Shows the status view with the
///   inline yellow re-auth banner; tapping "Re-enter Token" sets the
///   parent's `forceVerify` override.
enum FizzyAuthPhase: Equatable {
    case unconfigured
    case unpaired
    case paired
    case pairedNoToken
}
```

- [ ] **Step 2: Create the parent view**

Create `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift`:

```swift
import SwiftUI

/// Phase-switching parent that hosts one of three sub-views based on the
/// current `FizzyAuthState` + `FizzyBoardMapping` state. Owns:
/// - The `FizzySyncProvider` reference (passed down to sub-views).
/// - A `forceVerify` flag the Status view's "Re-enter Token" CTA sets
///   when authState was cleared by a 401 — the parent then routes to the
///   verify view regardless of the computed phase.
/// - A `refreshTrigger` (UUID @State) the sub-views bump on phase
///   transitions; mutating it forces SwiftUI to re-evaluate `phase`.
///
/// `phase` is recomputed on every body render, so as soon as a sub-view
/// writes `authState`/`mapping` and bumps `refreshTrigger`, the parent
/// renders the right next sub-view.
struct FizzyAuthView: View {

    let provider: FizzySyncProvider

    @State private var forceVerify: Bool = false
    @State private var refreshTrigger: UUID = UUID()

    var body: some View {
        let resolved = forceVerify ? FizzyAuthPhase.unconfigured : computePhase()
        Group {
            switch resolved {
            case .unconfigured:
                FizzyAuthVerifyView(
                    provider: provider,
                    onVerified: {
                        forceVerify = false
                        refreshTrigger = UUID()
                    }
                )
            case .unpaired:
                FizzyAuthPairView(
                    provider: provider,
                    onPaired: { refreshTrigger = UUID() },
                    onSignOutRequested: handleSignOut
                )
            case .paired, .pairedNoToken:
                FizzyAuthStatusView(
                    provider: provider,
                    showsReauthBanner: resolved == .pairedNoToken,
                    onReauthRequested: { forceVerify = true },
                    onSignOutRequested: handleSignOut,
                    onSyncFinished: { refreshTrigger = UUID() }
                )
            }
        }
        .id(refreshTrigger)
        .navigationTitle("Fizzy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func computePhase() -> FizzyAuthPhase {
        let configured = provider.authStateRef.isConfigured
        let paired = provider.mappingRef.isPaired
        switch (configured, paired) {
        case (false, false): return .unconfigured
        case (true,  false): return .unpaired
        case (true,  true):  return .paired
        case (false, true):  return .pairedNoToken
        }
    }

    private func handleSignOut() {
        Task {
            try? await provider.signOut()
            await MainActor.run {
                forceVerify = false
                refreshTrigger = UUID()
            }
        }
    }
}
```

- [ ] **Step 3: Build verify**

The parent references `FizzyAuthVerifyView`, `FizzyAuthPairView`, `FizzyAuthStatusView` — these are created in Tasks 4-6. The build will fail until then. Use a temporary stub strategy:

Before building, temporarily add empty stub views at the bottom of `FizzyAuthView.swift` so the file compiles in isolation:

```swift
// TEMPORARY STUBS — replaced by real sub-views in Tasks 4–6.
struct FizzyAuthVerifyView: View {
    let provider: FizzySyncProvider
    let onVerified: () -> Void
    var body: some View { Text("Verify (stub)") }
}
struct FizzyAuthPairView: View {
    let provider: FizzySyncProvider
    let onPaired: () -> Void
    let onSignOutRequested: () -> Void
    var body: some View { Text("Pair (stub)") }
}
struct FizzyAuthStatusView: View {
    let provider: FizzySyncProvider
    let showsReauthBanner: Bool
    let onReauthRequested: () -> Void
    let onSignOutRequested: () -> Void
    let onSyncFinished: () -> Void
    var body: some View { Text("Status (stub)") }
}
```

Build:

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyAuthPhase.swift \
        FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyAuthPhase enum + FizzyAuthView parent

FizzyAuthPhase: .unconfigured / .unpaired / .paired / .pairedNoToken
computed from authState + mapping.

FizzyAuthView: phase-switching parent. Owns the forceVerify override
that lets the status view's 'Re-enter Token' CTA route to the verify
sub-view without clearing the pairing. Hosts three sub-views (temporary
stubs that will be replaced in Tasks 4-6).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `FizzyAuthVerifyView`

The token-paste form. Calls `GET /my/identity`, stores token + first account's slug on success.

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift` — remove the `FizzyAuthVerifyView` stub.
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyAuthVerifyView.swift`

- [ ] **Step 1: Remove the stub**

Edit `FizzyAuthView.swift` and DELETE this block:

```swift
struct FizzyAuthVerifyView: View {
    let provider: FizzySyncProvider
    let onVerified: () -> Void
    var body: some View { Text("Verify (stub)") }
}
```

- [ ] **Step 2: Create the verify view**

Create `FenixKanban/Features/Sync/Fizzy/FizzyAuthVerifyView.swift`:

```swift
import SwiftUI

/// Token-paste + verify form. Sub-view of FizzyAuthView at phase .unconfigured
/// (or when forceVerify is set by a 401 recovery).
struct FizzyAuthVerifyView: View {

    let provider: FizzySyncProvider
    let onVerified: () -> Void

    @State private var enteredToken: String = ""
    @State private var verifyError: String?
    @State private var isVerifying: Bool = false
    @State private var verifyTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Paste your fizzy.bluefenix.net token", text: $enteredToken)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .monospaced()
                    .onSubmit(verify)
            } header: {
                Text("Access Token")
            } footer: {
                Text(LocalizedStringKey(
                    "Create or copy a token at [fizzy.bluefenix.net/me/access](https://fizzy.bluefenix.net/me/access)."
                ))
            }

            if let verifyError {
                Section {
                    Text(verifyError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button(action: verify) {
                    HStack {
                        if isVerifying { ProgressView().controlSize(.small) }
                        Text(isVerifying ? "Verifying…" : "Verify Connection")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(enteredToken.trimmingCharacters(in: .whitespaces).isEmpty || isVerifying)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .onDisappear { verifyTask?.cancel() }
    }

    private func verify() {
        verifyTask?.cancel()
        verifyError = nil
        let trimmed = enteredToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isVerifying = true
        verifyTask = Task { @MainActor in
            defer { isVerifying = false }
            // Build a throwaway client with empty slug — /my/identity skips slug interpolation.
            let client = provider.makeClient(accessToken: trimmed, accountSlug: "")
            do {
                let identity = try await client.get("/my/identity", as: FizzyIdentity.self)
                guard let firstAccount = identity.accounts.first else {
                    verifyError = "No accounts associated with this token."
                    return
                }
                provider.authStateRef.setAccessToken(trimmed)
                provider.authStateRef.setAccountSlug(firstAccount.slug)
                onVerified()
            } catch FizzyError.unauthorized {
                provider.authStateRef.clear()
                verifyError = "Invalid token. Check it on fizzy.bluefenix.net and paste again."
            } catch let error as FizzyError {
                verifyError = "Couldn't reach Fizzy: \(error)"
            } catch is CancellationError {
                // User dismissed; ignore.
            } catch {
                verifyError = "Couldn't reach Fizzy: \(error.localizedDescription)"
            }
        }
    }
}
```

- [ ] **Step 3: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyAuthVerifyView.swift \
        FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyAuthVerifyView — token paste + verify

Standard iOS grouped Form with a token TextField (.password
content type, monospaced, autocorrect off) and a primary "Verify
Connection" button. Calls GET /my/identity via FizzySyncProvider's
throwaway client (empty slug — /my/ paths skip slug interpolation).
On success: stores token + first account's slug, calls onVerified().
On 401: clears authState and shows inline 'Invalid token' message.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `FizzyAuthPairView`

The most complex sub-view: three pickers (local board, Fizzy board, first-sync mode), destructive-mode UX (color-coded segment + inline warning + adaptive primary + confirmation alert), and a dismissable backup recommendation banner.

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift` — remove the `FizzyAuthPairView` stub.
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift`

- [ ] **Step 1: Remove the stub**

Delete from `FizzyAuthView.swift`:

```swift
struct FizzyAuthPairView: View {
    let provider: FizzySyncProvider
    let onPaired: () -> Void
    let onSignOutRequested: () -> Void
    var body: some View { Text("Pair (stub)") }
}
```

- [ ] **Step 2: Create the pair view**

Create `FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift`:

```swift
import SwiftUI
import CoreData

/// Three pickers (local board, Fizzy board, first-sync mode) + destructive
/// UX for replaceLocalWithFizzy + dismissable backup recommendation banner.
/// Sub-view of FizzyAuthView at phase .unpaired.
struct FizzyAuthPairView: View {

    let provider: FizzySyncProvider
    let onPaired: () -> Void
    let onSignOutRequested: () -> Void

    @AppStorage("fizzy.pair.backupBannerDismissed") private var backupBannerDismissed = false

    @State private var localBoards: [Board] = []
    @State private var remoteBoards: [RemoteBoard] = []
    @State private var loadError: String?
    @State private var isLoading: Bool = true

    @State private var pickedLocalBoardID: UUID?
    @State private var pickedFizzyBoardID: String?
    @State private var pickedMode: FirstSyncMode = .pushLocalToFizzy

    @State private var isSyncing = false
    @State private var pairError: String?
    @State private var pairTask: Task<Void, Never>?
    @State private var showDestructiveConfirm = false

    private var pickedLocalBoard: Board? {
        guard let id = pickedLocalBoardID else { return nil }
        return localBoards.first { $0.id == id }
    }

    private var pickedRemoteBoard: RemoteBoard? {
        guard let id = pickedFizzyBoardID else { return nil }
        return remoteBoards.first { $0.id == id }
    }

    private var pickedLocalBoardCardCount: Int {
        guard let board = pickedLocalBoard else { return 0 }
        return ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
            sum + (((col.cards as? Set<Card>) ?? []).count)
        }
    }

    var body: some View {
        Form {
            if !backupBannerDismissed {
                Section {
                    backupBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if isLoading {
                Section { ProgressView("Loading Fizzy boards…") }
            } else if let loadError {
                Section {
                    ContentUnavailableView(
                        "Couldn't load Fizzy boards",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    Button("Try Again") { Task { await loadRemoteBoards() } }
                }
            } else {
                Section("Local Board") {
                    Picker("Board", selection: $pickedLocalBoardID) {
                        ForEach(localBoards, id: \.id) { board in
                            let count = ((board.columns as? Set<Column>) ?? []).reduce(0) { sum, col in
                                sum + (((col.cards as? Set<Card>) ?? []).count)
                            }
                            // `board.id` is already `UUID?` (CoreData optional); pass it
                            // directly so the tag type matches the selection binding's
                            // `UUID?`. Wrapping in `Optional(...)` would produce `UUID??`.
                            Text("\(board.name ?? "(untitled)") (\(count) cards)")
                                .tag(board.id)
                        }
                    }
                }

                Section("Fizzy Board") {
                    Picker("Board", selection: $pickedFizzyBoardID) {
                        ForEach(remoteBoards) { remote in
                            // `remote.id` is non-optional `String`; cast to `String?`
                            // so the tag matches the selection binding.
                            Text(remote.name).tag(remote.id as String?)
                        }
                    }
                }

                Section {
                    Picker("First Sync", selection: $pickedMode) {
                        Text("Push").tag(FirstSyncMode.pushLocalToFizzy)
                        Text("Replace").tag(FirstSyncMode.replaceLocalWithFizzy)
                        Text("Merge").tag(FirstSyncMode.mergeIfNoConflicts)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("First Sync Mode")
                } footer: {
                    Text(modeHelpText)
                        .foregroundStyle(pickedMode == .replaceLocalWithFizzy ? .red : .secondary)
                }

                if pickedMode == .replaceLocalWithFizzy, pickedLocalBoardCardCount > 0 {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("This will delete all \(pickedLocalBoardCardCount) cards on \"\(pickedLocalBoard?.name ?? "")\".")
                                    .font(.callout).fontWeight(.semibold)
                                Text("Cannot be undone without restoring a backup. You'll confirm again on Pair & Sync.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let pairError {
                    Section {
                        Text(pairError)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button(action: pairTapped) {
                        HStack {
                            if isSyncing { ProgressView().controlSize(.small) }
                            Text(primaryButtonLabel)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(pickedMode == .replaceLocalWithFizzy ? .red : .accentColor)
                    .disabled(pickedLocalBoardID == nil || pickedFizzyBoardID == nil || isSyncing)
                }

                Section {
                    Button("Sign Out", role: .destructive, action: onSignOutRequested)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task { await initialLoad() }
        .onDisappear { pairTask?.cancel() }
        .alert("Delete and Replace?", isPresented: $showDestructiveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete & Replace", role: .destructive) { runPair() }
        } message: {
            Text("This will delete all \(pickedLocalBoardCardCount) cards on \"\(pickedLocalBoard?.name ?? "")\" and replace them with cards from Fizzy. This cannot be undone.")
        }
    }

    private var primaryButtonLabel: String {
        if isSyncing { return "Syncing…" }
        return pickedMode == .replaceLocalWithFizzy ? "Delete & Replace" : "Pair & Sync"
    }

    private var modeHelpText: String {
        switch pickedMode {
        case .pushLocalToFizzy:
            return "Push — uploads every local card on this board to Fizzy. Pre-existing Fizzy cards stay (non-destructive)."
        case .replaceLocalWithFizzy:
            return "Replace — DELETES local cards on this board and pulls Fizzy's state. Destructive."
        case .mergeIfNoConflicts:
            return "Merge — pushes local-only and pulls Fizzy-only cards. Same-title collisions are logged and skipped."
        }
    }

    private var backupBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("Export a backup first")
                    .font(.callout).fontWeight(.semibold)
                Text("Recommended before your first sync — recoverable in case anything looks wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink("Open Backup") {
                    BackupSettingsView(persistence: provider.persistenceRef)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button {
                backupBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
        .padding(.horizontal)
    }

    @MainActor
    private func initialLoad() async {
        await loadLocalBoards()
        await loadRemoteBoards()
        if pickedLocalBoardID == nil { pickedLocalBoardID = localBoards.first?.id }
        if pickedFizzyBoardID == nil { pickedFizzyBoardID = remoteBoards.first?.id }
    }

    @MainActor
    private func loadLocalBoards() async {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        do {
            localBoards = try provider.persistenceRef.viewContext.fetch(request)
        } catch {
            loadError = "Local boards: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadRemoteBoards() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            remoteBoards = try await provider.fetchRemoteBoards()
        } catch {
            loadError = "\(error)"
        }
    }

    private func pairTapped() {
        if pickedMode == .replaceLocalWithFizzy, pickedLocalBoardCardCount > 0 {
            showDestructiveConfirm = true
        } else {
            runPair()
        }
    }

    private func runPair() {
        guard let localID = pickedLocalBoardID, let fizzyID = pickedFizzyBoardID else { return }
        guard let engine = provider.makeEngine() else {
            pairError = "Provider isn't authenticated — sign in first."
            return
        }
        provider.mappingRef.setPairing(localBoardID: localID, fizzyBoardID: fizzyID)
        let mode = pickedMode
        pairError = nil
        isSyncing = true
        pairTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                _ = try await engine.syncFirst(mode: mode)
                onPaired()
            } catch FizzyError.unauthorized {
                // Engine cleared authState. Parent will recompute phase to
                // .pairedNoToken on next render — no extra action needed here.
                onPaired()
            } catch is CancellationError {
                // ignore
            } catch let error as FizzyError {
                pairError = "Sync failed: \(error)"
            } catch {
                pairError = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
```

- [ ] **Step 3: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift \
        FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyAuthPairView — three pickers + destructive UX

Local board picker (from CoreData), Fizzy board picker (from
fetchRemoteBoards), first-sync mode segmented control (default
.pushLocalToFizzy). Selecting .replaceLocalWithFizzy:
- tints the segment red
- shows an inline warning row with card count
- swaps the primary button to "Delete & Replace" (red)
- requires confirmation alert before running

Dismissable backup recommendation banner at the top
(per-UserDefaults dismissal state). Sign Out destructive button
at the bottom.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `FizzyAuthStatusView`

Paired state UI: status hero, Sync Now, Sign Out, inline 401 banner.

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift` — remove the `FizzyAuthStatusView` stub.
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift`

- [ ] **Step 1: Remove the stub**

Delete from `FizzyAuthView.swift`:

```swift
struct FizzyAuthStatusView: View {
    let provider: FizzySyncProvider
    let showsReauthBanner: Bool
    let onReauthRequested: () -> Void
    let onSignOutRequested: () -> Void
    let onSyncFinished: () -> Void
    var body: some View { Text("Status (stub)") }
}
```

- [ ] **Step 2: Create the status view**

Create `FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift`:

```swift
import SwiftUI
import CoreData

/// Paired state UI: status hero, Sync Now, Sign Out. Shows the inline
/// yellow 401 banner above the hero when showsReauthBanner is true
/// (computed by parent from phase == .pairedNoToken). Sub-view of
/// FizzyAuthView at phase .paired and .pairedNoToken.
struct FizzyAuthStatusView: View {

    let provider: FizzySyncProvider
    let showsReauthBanner: Bool
    let onReauthRequested: () -> Void
    let onSignOutRequested: () -> Void
    let onSyncFinished: () -> Void

    @State private var isSyncing: Bool = false
    @State private var syncError: String?
    @State private var syncTask: Task<Void, Never>?
    @State private var lastSyncedRefresh: UUID = UUID()
    @State private var showSignOutConfirm = false

    private var fizzyBoardName: String {
        provider.mappingRef.fizzyBoardID ?? "—"
    }

    private var localBoardName: String {
        guard let id = provider.mappingRef.localBoardID else { return "—" }
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? provider.persistenceRef.viewContext.fetch(request).first?.name) ?? "—"
    }

    private var lastSyncDescription: String {
        guard let lastSync = provider.mappingRef.lastSyncAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSync, relativeTo: .now)
    }

    private var cardsSyncedCount: Int {
        guard let id = provider.mappingRef.localBoardID else { return 0 }
        let request: NSFetchRequest<Card> = Card.fetchRequest()
        request.predicate = NSPredicate(format: "fizzyID != nil AND column.board.id == %@", id as CVarArg)
        return (try? provider.persistenceRef.viewContext.count(for: request)) ?? 0
    }

    var body: some View {
        Form {
            if showsReauthBanner {
                Section {
                    reauthBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Status") {
                LabeledContent("Local Board", value: localBoardName)
                LabeledContent("Fizzy Board", value: fizzyBoardName)
                LabeledContent("Last Sync", value: lastSyncDescription)
                LabeledContent("Cards Synced", value: "\(cardsSyncedCount)")
            }

            if let syncError {
                Section {
                    Text(syncError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button(action: syncNow) {
                    HStack {
                        if isSyncing { ProgressView().controlSize(.small) }
                        Text(syncButtonLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(showsReauthBanner || isSyncing)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirm = true
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("Clears your Fizzy token and pairing. Local cards are kept.")
            }
        }
        .id(lastSyncedRefresh)
        .onDisappear { syncTask?.cancel() }
        .alert("Sign out of Fizzy?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive, action: onSignOutRequested)
        } message: {
            Text("Local cards are kept.")
        }
    }

    private var syncButtonLabel: String {
        if showsReauthBanner { return "Sync Paused" }
        if isSyncing { return "Syncing…" }
        return "Sync Now"
    }

    private var reauthBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Re-enter Fizzy access token")
                    .font(.callout).fontWeight(.semibold)
                Text("Your token was revoked or expired. Sync paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Re-enter Token", action: onReauthRequested)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
        .padding(.horizontal)
    }

    private func syncNow() {
        guard !isSyncing else { return }
        guard let engine = provider.makeEngine() else {
            syncError = "Provider isn't authenticated."
            return
        }
        syncError = nil
        isSyncing = true
        syncTask = Task { @MainActor in
            defer { isSyncing = false }
            do {
                _ = try await engine.sync()
                lastSyncedRefresh = UUID()  // force LabeledContent re-eval for lastSyncedDescription
                onSyncFinished()
            } catch FizzyError.unauthorized {
                // Engine cleared authState; parent will route to .pairedNoToken
                // on next render → reauth banner appears here.
                onSyncFinished()
            } catch is CancellationError {
                // ignore
            } catch let error as FizzyError {
                syncError = "Sync failed: \(error)"
            } catch {
                syncError = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
```

- [ ] **Step 3: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift \
        FenixKanban/Features/Sync/Fizzy/FizzyAuthView.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyAuthStatusView — paired status + 401 banner

Status hero (Local Board, Fizzy Board, Last Sync via
RelativeDateTimeFormatter, Cards Synced via live CoreData count of
fizzyID-nonnil cards on the paired board). Primary "Sync Now"
button calls engine.sync(); "Sign Out" destructive button at
bottom with confirmation alert.

Inline yellow 401 banner appears above the status when
showsReauthBanner is true (parent passes from phase ==
.pairedNoToken). "Re-enter Token" CTA invokes onReauthRequested,
which flips parent's forceVerify flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `SyncSettingsView`

Replace the simple HStack row with a status-badge NavigationLink that pushes `FizzyAuthView`. Remove the empty state (FizzySyncProvider will be registered at app launch in Task 8).

**Files:**
- Modify: `FenixKanban/Features/Sync/SyncSettingsView.swift`

- [ ] **Step 1: Rewrite the view**

Replace the entire contents of `FenixKanban/Features/Sync/SyncSettingsView.swift` with:

```swift
import SwiftUI

struct SyncSettingsView: View {
    let registry = PluginRegistry.shared

    var body: some View {
        List {
            Section("Sync Providers") {
                ForEach(registry.providers, id: \.providerName) { provider in
                    if let fizzy = provider as? FizzySyncProvider {
                        NavigationLink {
                            FizzyAuthView(provider: fizzy)
                        } label: {
                            providerRow(fizzy)
                        }
                    } else {
                        providerRow(provider)
                    }
                }
            } footer: {
                Text("Sync your boards with cards on remote services.")
            }
        }
        .navigationTitle("Board Sync")
    }

    @ViewBuilder
    private func providerRow(_ provider: any BoardSyncProvider) -> some View {
        HStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.providerName)
                Text(rowSubtitle(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(for: provider)
        }
    }

    private func rowSubtitle(_ provider: any BoardSyncProvider) -> String {
        guard let fizzy = provider as? FizzySyncProvider else {
            return provider.isAuthenticated ? "Connected" : "Not set up"
        }
        if fizzy.mappingRef.isPaired && !fizzy.authStateRef.isConfigured {
            return "Tap to re-enter token"
        }
        if fizzy.isAuthenticated && fizzy.mappingRef.isPaired {
            if let last = fizzy.mappingRef.lastSyncAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return "Synced \(formatter.localizedString(for: last, relativeTo: .now))"
            }
            return "Paired"
        }
        if fizzy.isAuthenticated {
            return "Pair a board"
        }
        return "Not set up"
    }

    @ViewBuilder
    private func statusBadge(for provider: any BoardSyncProvider) -> some View {
        if let fizzy = provider as? FizzySyncProvider {
            if fizzy.mappingRef.isPaired && !fizzy.authStateRef.isConfigured {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else if fizzy.isAuthenticated && fizzy.mappingRef.isPaired {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else if provider.isAuthenticated {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
```

- [ ] **Step 2: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Sync/SyncSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(sync): SyncSettingsView row badges + navigation push

Replaces the static auth-checkmark row with a status-badge
NavigationLink that pushes FizzyAuthView for Fizzy providers.
Badges:
- green check: authenticated AND paired
- orange exclamation: paired but authState cleared (401 mid-session)
- no badge: not configured

Subtitle reflects state: "Not set up" / "Pair a board" /
"Tap to re-enter token" / "Synced 2 min ago".

Removes the "No Sync Providers" empty state — FizzySyncProvider
will be registered at app launch (Task 8) so the list is never empty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Register `FizzySyncProvider` in `FenixKanbanApp.init()`

The wire-up that makes everything live.

**Files:**
- Modify: `FenixKanban/FenixKanbanApp.swift`

- [ ] **Step 1: Add the registration block**

In `FenixKanban/FenixKanbanApp.swift`, find the `init()` body. After the existing `AppDependencyManager.shared.add(dependency: navigatorValue)` line at the end of `init()`, append:

```swift
        // Register Fizzy as a BoardSyncProvider. The provider is constructed
        // with the production singletons (Keychain-backed FizzyAuthState,
        // standard UserDefaults-backed FizzyBoardMapping, the shared
        // PersistenceController). It is registered before the first scene
        // renders so SyncSettingsView's list is populated on cold launch.
        let fizzyProvider = FizzySyncProvider(
            authState: FizzyAuthState(),
            mapping: FizzyBoardMapping(),
            persistence: PersistenceController.shared
        )
        PluginRegistry.shared.register(fizzyProvider)
```

- [ ] **Step 2: Build + verify**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite for regression**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|Failing tests" | tail -3
```

Expected: `Test run with ~217 tests in ~57 suites passed`
(Phase 4c baseline 211 + Phase 5's 6 new = 217).

If the first run hits a simulator preflight error, re-run — known cold-start flake.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): register FizzySyncProvider at app launch

PluginRegistry.shared gains the Fizzy provider before the first
scene renders. SyncSettingsView's list is populated on cold launch
regardless of whether the user has authenticated. The provider
holds production singletons (Keychain authState, standard
UserDefaults mapping, shared PersistenceController) for the app
process lifetime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: TDD status doc

**File:** Modify `TDD_IMPLEMENTATION_STATUS.md` — append Phase 5 entry.

- [ ] **Step 1: Append entry**

After the existing Phase 4c entry, append:

```markdown

### Fizzy Integration — Phase 5: UI ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-26

**🔴 Red Phase:**
- 6 new tests in `FizzySyncProviderTests`:
  - providerName == "Fizzy"
  - isAuthenticated mirrors authState.isConfigured
  - authenticate() throws .requiresInteractiveAuth
  - signOut clears authState + mapping without touching Cards
  - fetchRemoteBoards maps FizzyBoard DTOs to RemoteBoard
  - sync(_:_:) translates FizzySyncResult → public SyncResult
- Sub-views (Verify / Pair / Status) are SwiftUI surfaces validated via
  manual UAT (see "Manual UAT" below); no XCUITest at this stage.

**🟢 Green Phase:**
- `FizzyError.requiresInteractiveAuth` new case — protocol-bridging signal
  for `BoardSyncProvider.authenticate()`.
- `FizzySyncProvider` (`@MainActor final class`) — BoardSyncProvider
  conformance. Holds authState/mapping/persistence; rebuilds FizzyClient +
  engine on demand so token changes propagate without re-registration.
- `FizzyAuthPhase` enum — `.unconfigured / .unpaired / .paired /
  .pairedNoToken` computed from authState + mapping.
- `FizzyAuthView` parent — phase switch with `forceVerify` override for
  401 recovery; hosts three sub-views.
- `FizzyAuthVerifyView` — token paste form, calls `GET /my/identity`,
  stores token + first account's slug on success. 401 clears authState
  and surfaces "Invalid token" inline.
- `FizzyAuthPairView` — three pickers (local board, Fizzy board, mode),
  destructive-mode UX (red-tinted segment + warning row + adaptive
  primary button + confirmation alert), dismissable backup banner with
  deep-link to BackupSettingsView.
- `FizzyAuthStatusView` — status hero (board names, last sync via
  RelativeDateTimeFormatter, live Card count), Sync Now button, Sign Out
  destructive button, inline yellow 401 banner above hero when
  `pairedNoToken`.
- `SyncSettingsView` — new row badge (green ✓ / orange ! / none) and
  NavigationLink push to FizzyAuthView; "No Providers" empty state
  removed.
- `FenixKanbanApp.init()` — registers FizzySyncProvider at launch.

**🔵 Refactor Phase:**
- All async operations stored in `@State var task: Task<Void, Never>?`
  and cancelled `.onDisappear`.
- `forceVerify` override lets the status view's "Re-enter Token" route
  to the verify view without clearing the pairing — pairing persists
  through re-auth.
- `refreshTrigger: UUID` on the parent forces SwiftUI to re-evaluate
  phase after sub-views mutate authState/mapping.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md`
**Plan:** `docs/superpowers/plans/2026-05-26-fizzy-phase-5-ui.md`

**Test Coverage:** 6 new tests; full suite ~217/217.

**Manual UAT (against real fizzy.bluefenix.net):**
1. Cold launch, no Fizzy setup → Settings → Board Sync → Fizzy row
   chevron-only → tap → verify with valid token → account name appears
   → board pickers materialize → pair with default mode (.push) →
   returns to status view, "Sync Now" enabled.
2. Edit a card title in FenixKanban → tap "Sync Now" → refresh
   fizzy.bluefenix.net in browser → title updated.
3. Edit a card title in Fizzy → tap "Sync Now" → local card title
   updated.
4. Toggle `golden` in Fizzy → "Sync Now" → local card's gold state
   matches.
5. Pick `.replace` for a NEW pairing → "Pair & Sync" → confirmation
   alert with card count → confirm → local cards wiped + replaced with
   Fizzy's; other local boards' cards unchanged.
6. Revoke token in Fizzy admin → "Sync Now" → yellow banner above
   status hero → tap "Re-enter Token" → re-verify → banner clears on
   next sync.
7. Sign Out → mapping clears, authState clears, local cards retained →
   re-pair to same Fizzy board with `.merge` → orphan-claim re-binds
   cards by title+createdAt.

**Out of scope (deferred):**
1. Foreground polling timer (5-min while `scenePhase == .active`) → Phase 6.
2. CardView cloud badges → Phase 6.
3. Phase 4c reviewer follow-ups (BackupExporter off-main-actor, BackupDocument: Sendable, Data section split, schema-name constant) → Phase 6 polish or separate Phase 4d.

**What ships:** A complete manual-sync UX for one Fizzy account/board pairing,
with verified backup safety net (Phase 4c) and proven board-isolation
guarantees. Phase 6 adds polling and per-card sync badges.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 5 (UI)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification + manual UAT

- [ ] **Step 1: Full iOS suite**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|Failing tests" | tail -3
```

Expected: `Test run with ~217 tests in ~57 suites passed`.

Re-run once if the first attempt hits the known simulator preflight flake.

- [ ] **Step 2: macOS clean build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Branch state**

```bash
git log --oneline <Phase 5 plan SHA>..HEAD
git status -sb
```

Expected: ~9 new commits on top of the plan; clean working tree.

- [ ] **Step 4: Manual UAT against fizzy.bluefenix.net**

Run through the 7 UAT items listed in Task 9's TDD entry. Use a real Fizzy token. For UAT item 5 (`.replace` mode), **export a backup first** via Settings → Data → Backup so the destructive test can be undone if the result is surprising.

For each UAT item, record pass/fail in the PR description. If any fail, file a follow-up issue and either fix-in-PR or note as known-issue depending on severity.

- [ ] **Step 5: Ready-for-PR report**

Suggested PR title:

> `feat(fizzy): Phase 5 — UI (auth, pair, sync, 401 recovery)`

Suggested PR body skeleton:

```markdown
## Summary
- `FizzySyncProvider` (BoardSyncProvider conformance) registered at
  app launch; SyncSettingsView shows it with status badges.
- New `FizzyAuthView` parent + three sub-views: paste a token, pair
  a board, sync manually. Inline 401 banner with "Re-enter Token"
  recovery; pairing persists through re-auth.
- 6 new tests; full suite ~217/217.
- First time pointed at real fizzy.bluefenix.net — UAT pass list in
  TDD doc.

## Test plan
- [x] iOS Simulator full suite green.
- [x] macOS clean build.
- [x] FizzySyncProvider 6/6 unit tests pass.
- [x] Manual UAT items 1–7 pass (see TDD doc).

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-phase-5-ui-design.md`
- Plan: `docs/superpowers/plans/2026-05-26-fizzy-phase-5-ui.md`
- Phase 6 (polling timer + cloud badges) is the natural follow-on.
```

---

## Success criteria recap

- [ ] `FizzyError.requiresInteractiveAuth` case added.
- [ ] `FizzySyncProvider` conforms to `BoardSyncProvider`; 6 unit tests pass.
- [ ] `FizzyAuthPhase` enum has 4 cases.
- [ ] `FizzyAuthView` parent switches sub-views via `phase` + `forceVerify` override.
- [ ] `FizzyAuthVerifyView` calls `GET /my/identity`, stores token + first account's slug.
- [ ] `FizzyAuthPairView` shows 3 pickers + destructive-mode UX (color + warning + adaptive primary + confirmation alert) + dismissable backup banner.
- [ ] `FizzyAuthStatusView` shows status + Sync Now + Sign Out + 401 banner when `.pairedNoToken`.
- [ ] `SyncSettingsView` shows Fizzy row with status badges; pushes `FizzyAuthView`.
- [ ] `FenixKanbanApp.init()` registers the provider.
- [ ] No `.background(.systemBackground)` or `.background(.windowBackground)` in any new view (Liquid Glass preserved).
- [ ] iOS suite green at ~217/217.
- [ ] macOS clean build succeeds.
- [ ] TDD doc updated.
- [ ] All 7 UAT items pass against real fizzy.bluefenix.net.
