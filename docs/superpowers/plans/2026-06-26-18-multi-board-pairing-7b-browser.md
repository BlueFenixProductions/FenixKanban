# Multi-board pairing — Phase 7b (unified board browser) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `FizzyBoardBrowserView` that reconciles local + remote boards into one grouped list (Synced / Local only / On Fizzy only) with per-row sync state and paired-row actions, reachable from Settings — building on the merged Phase 7a core.

**Architecture:** A pure reconciliation function joins the device-local pairing store, the local CoreData `Board` set, and the remote `GET /boards` list into immutable `BoardBrowserRow` values. A thin `@Observable @MainActor` view model loads the three inputs and rebuilds rows; the SwiftUI view renders them. Transient per-row syncing/error state lives in a new per-board activity registry (`FizzyBoardSyncActivity`) owned by the provider, so the view stays a pure projection that cannot drift.

**Tech Stack:** Swift, SwiftUI, CoreData, Swift Testing (`@Suite`/`@Test`/`#expect`), XcodeGen (`make generate`), MockURLProtocol/`MockHTTPState` for headless network tests.

## Global Constraints

- **Swift Testing, not XCTest.** New suites use `import Testing`, `@Suite`, `@Test`, `#expect`/`#require`. Suites that call `context.save()` on a viewContext must be `@MainActor`.
- **Stores are device-local sidecars, injected in tests.** Tests construct `FizzyBoardPairingStore(fileURL:)` and `FizzyCardPairingStore(fileURL:)` pointing at temp files; never touch the real Application Support sidecar. Auth uses `FizzyAuthState(keyPrefix:)` with a per-test UUID prefix.
- **Network is stubbed** via `MockHTTPState` + `mock.makeSession()` + `mock.handler`. No live HTTP in tests.
- **New `.swift` files require XcodeGen regen.** Both `FenixKanban` and `FenixKanbanTests` targets glob their directory (`- path: FenixKanban` / `- path: FenixKanbanTests`), so a new file is picked up by `make generate`. Stage the regenerated project file by explicit path: `git add FenixKanban.xcodeproj/project.pbxproj`.
- **Stage files by explicit path only.** Never `git add -A` / `git add .` (duplicate `.xcodeproj` refs caused issue #28). No `Co-Authored-By` trailer. Branch off the 7a branch / merged `develop`, never commit on a default-branch name.
- **Reconciliation rule (the join), copied from the spec:** each pairing → a `.paired` row (resolve its local `Board` + remote board); each local `Board` with no pairing → *Local only*; each remote board with no pairing → *On Fizzy only*. Rows are a pure projection of the pairing store + per-board activity; no pairing state lives in the view.
- **Unpair never touches `Card` data** — it only removes the pairing row (`provider.unpair(localBoardID:)` → `store.remove`). Re-pairing re-binds via orphan-claim.

## Scope & deviations from the design

The approved design (`docs/superpowers/specs/2026-06-26-multi-board-pairing-design.md`, Phase 7b section) lists the browser as shared by **Settings and onboarding**, with **Create-on-fizzy / Add-to-FK / Link-existing** action buttons in the Local-only / On-Fizzy-only sections.

This plan keeps 7b **purely additive and regression-free** (honoring 7a's "zero UX regression" principle):

- The browser is mounted as a new **"Manage Boards"** screen reachable from `SyncSettingsView`. The existing single-pair flow (`FizzyAuthView` → verify/pair/status) is **left untouched** — users keep a working way to pair.
- **Local-only / On-Fizzy-only rows are display-only** in 7b (they show what is unpaired, which makes the reconciliation join fully testable and immediately useful). Their **Create / Add / Link action buttons, plus promoting the browser to the primary post-auth/onboarding home, are deferred to Phase 7c** (where the create/pull/link flows are built).

## File Structure

- **Create** `FenixKanban/Features/Sync/Fizzy/FizzyBoardSyncActivity.swift` — per-board transient activity registry (`@Observable`, board UUID → `SyncActivityState.Phase`). Task 1.
- **Modify** `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` — own the registry, update it in the round-robin loop + manual `sync(boardId:)`, expose `boardActivityRef`; collapse the byte-identical `makeEngine(for:)` (Task 5 cleanup). Tasks 1 & 5.
- **Create** `FenixKanban/Features/Sync/Fizzy/BoardBrowserRow.swift` — `BoardBrowserRow` value type + the pure `reconcile(...)` join. Task 2.
- **Create** `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift` — `@Observable @MainActor` VM: load/refresh + paired-row action wrappers. Tasks 3 & 4.
- **Create** `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift` — grouped SwiftUI list. Task 4.
- **Modify** `FenixKanban/Features/Sync/SyncSettingsView.swift` — add the "Manage Boards" navigation link. Task 5.
- **Create** `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardSyncActivityTests.swift` — registry + provider-integration tests. Task 1.
- **Create** `FenixKanbanTests/Features/Sync/Fizzy/BoardBrowserRowReconcileTests.swift` — the four join cases + ordering. Task 2.
- **Create** `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift` — VM load/error/refresh + action tests. Tasks 3 & 4.
- **Modify (doc-comment sweep, behavior-neutral)** the 5 stale `FizzyBoardMapping` breadcrumbs deferred from 7a. Task 5.

---

### Task 1: Per-board sync-activity registry

**Files:**
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyBoardSyncActivity.swift`
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (add registry property + accessor; update `triggerSync(activityState:)` loop and `sync(boardId:remoteProjectId:)`)
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardSyncActivityTests.swift`

**Interfaces:**
- Consumes: `SyncActivityState.Phase` (existing enum: `.idle`, `.syncing`, `.error(String)`, `Equatable`); the 7a provider round-robin in `triggerSync(activityState:)`; the existing test scaffold `MultiBoardHarness` (in `FenixKanbanTests/Services/Fizzy/FizzySyncEngineMultiBoardTests.swift`) with `seedPairedBoard(name:fizzyBoardID:)`, `provider`, `tearDown()`.
- Produces:
  - `final class FizzyBoardSyncActivity` (`@Observable @MainActor`) with `func phase(for: UUID) -> SyncActivityState.Phase`, `func markSyncing(_: UUID)`, `func markIdle(_: UUID)`, `func markError(_: UUID, _: String)`, and `private(set) var phases: [UUID: SyncActivityState.Phase]`.
  - `var boardActivityRef: FizzyBoardSyncActivity` on `FizzySyncProvider`.

- [ ] **Step 1: Write the failing registry test**

Create `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardSyncActivityTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardSyncActivity")
@MainActor
struct FizzyBoardSyncActivityTests {

    @Test("unknown board defaults to idle")
    func defaultsIdle() {
        let activity = FizzyBoardSyncActivity()
        #expect(activity.phase(for: UUID()) == .idle)
    }

    @Test("transitions are per-board and independent")
    func perBoardTransitions() {
        let activity = FizzyBoardSyncActivity()
        let a = UUID(), b = UUID()
        activity.markSyncing(a)
        activity.markError(b, "boom")
        #expect(activity.phase(for: a) == .syncing)
        #expect(activity.phase(for: b) == .error("boom"))
        activity.markIdle(a)
        #expect(activity.phase(for: a) == .idle)
        #expect(activity.phase(for: b) == .error("boom"))   // b unaffected
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardSyncActivityTests`
Expected: FAIL to build with "cannot find 'FizzyBoardSyncActivity' in scope".

- [ ] **Step 3: Implement the registry**

Create `FenixKanban/Features/Sync/Fizzy/FizzyBoardSyncActivity.swift`:

```swift
import Foundation
import Observation

/// Per-board transient sync activity, keyed by local board UUID (issue #18,
/// Phase 7b). The board browser observes this so each row can show an
/// in-progress spinner or an error line independently of the others. Reuses
/// `SyncActivityState.Phase` (Phase 6) as the per-board lifecycle; a board with
/// no recorded entry reads as `.idle`.
@Observable
@MainActor
final class FizzyBoardSyncActivity {

    private(set) var phases: [UUID: SyncActivityState.Phase] = [:]

    func phase(for boardID: UUID) -> SyncActivityState.Phase {
        phases[boardID] ?? .idle
    }

    func markSyncing(_ boardID: UUID) { phases[boardID] = .syncing }
    func markIdle(_ boardID: UUID) { phases[boardID] = .idle }
    func markError(_ boardID: UUID, _ message: String) { phases[boardID] = .error(message) }
}
```

- [ ] **Step 4: Regenerate the project and run the registry test**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardSyncActivityTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing provider-integration test**

Append to `FizzyBoardSyncActivityTests.swift` a suite that drives the provider's round-robin through `MultiBoardHarness` and asserts boards land `.idle` after a successful cycle:

```swift
@Suite("FizzyBoardSyncActivity provider integration", .serialized)
@MainActor
struct FizzyBoardActivityProviderTests {

    @Test("successful round-robin marks each synced board idle")
    func roundRobinMarksIdle() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")

        await h.provider.triggerSync(activityState: SyncActivityState())

        #expect(h.provider.boardActivityRef.phase(for: a.id!) == .idle)
        #expect(h.provider.boardActivityRef.phase(for: b.id!) == .idle)
    }
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardActivityProviderTests`
Expected: FAIL to build with "value of type 'FizzySyncProvider' has no member 'boardActivityRef'".

- [ ] **Step 7: Wire the registry into the provider**

In `FizzySyncProvider.swift`, add the stored registry near `currentBoardID` (after the `// MARK: - Per-board routing` section's `var currentBoardID: UUID?`):

```swift
    /// Per-board transient activity for the board browser (issue #18, Phase 7b).
    private let boardActivity = FizzyBoardSyncActivity()

    /// Exposes the per-board activity registry to the board-browser UI.
    var boardActivityRef: FizzyBoardSyncActivity { boardActivity }
```

In `triggerSync(activityState:)`, replace the round-robin `for` loop body so each board's phase is recorded:

```swift
        for boardID in order {
            guard let engine = makeEngine(for: boardID) else { continue }
            boardActivity.markSyncing(boardID)
            do {
                let result = try await engine.sync(localBoardID: boardID)
                aggregate.merge(result)
                if let e = result.errors.first {
                    boardActivity.markError(boardID, e)
                    if firstError == nil { firstError = e }
                } else {
                    boardActivity.markIdle(boardID)
                }
            } catch {
                boardActivity.markError(boardID, error.localizedDescription)
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
```

In `sync(boardId:remoteProjectId:)`, record activity around the engine call (keep the existing `WidgetCenter` reload + `SyncResult` mapping):

```swift
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult {
        guard let engine = makeEngine(for: boardId) else {
            throw FizzyError.requiresInteractiveAuth
        }
        boardActivity.markSyncing(boardId)
        do {
            let result = try await engine.sync(localBoardID: boardId)
            if let e = result.errors.first {
                boardActivity.markError(boardId, e)
            } else {
                boardActivity.markIdle(boardId)
            }
            WidgetCenter.shared.reloadAllTimelines()
            return SyncResult(
                itemsCreated: result.itemsCreated,
                itemsUpdated: result.itemsUpdated,
                itemsDeleted: result.itemsDeleted,
                errors: result.errors,
                syncDate: .now
            )
        } catch {
            boardActivity.markError(boardId, error.localizedDescription)
            throw error
        }
    }
```

- [ ] **Step 8: Run the integration test + the 7a scheduler tests (no regression)**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardActivityProviderTests -only-testing:FenixKanbanTests/FizzyMultiBoardSchedulerTests -only-testing:FenixKanbanTests/FizzySyncProviderTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardSyncActivity.swift \
        FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardSyncActivityTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#18): per-board sync-activity registry for the board browser"
```

---

### Task 2: Reconciliation join (`BoardBrowserRow` + `reconcile`)

**Files:**
- Create: `FenixKanban/Features/Sync/Fizzy/BoardBrowserRow.swift`
- Test: `FenixKanbanTests/Features/Sync/Fizzy/BoardBrowserRowReconcileTests.swift`

**Interfaces:**
- Consumes: `RemoteBoard` (`id: String`, `name: String`, from `BoardSyncProvider.swift`); `FizzyBoardPairing` (`localBoardID: UUID`, `fizzyBoardID: String`, `fizzyBoardName: String?`, `lastSyncAt: Date?`, `syncEnabled: Bool`).
- Produces:
  - `struct BoardBrowserRow: Identifiable, Equatable` with `enum Kind { case paired, localOnly, remoteOnly }` and fields `id: String`, `kind: Kind`, `localBoardID: UUID?`, `fizzyBoardID: String?`, `title: String`, `lastSyncAt: Date?`, `syncEnabled: Bool`.
  - `struct BoardBrowserRow.LocalBoardInfo: Equatable { let id: UUID; let name: String }`.
  - `static func BoardBrowserRow.reconcile(localBoards: [LocalBoardInfo], remoteBoards: [RemoteBoard], pairings: [FizzyBoardPairing]) -> [BoardBrowserRow]` — paired rows first (pairing-store order), then local-only, then remote-only.

- [ ] **Step 1: Write the failing reconcile test**

Create `FenixKanbanTests/Features/Sync/Fizzy/BoardBrowserRowReconcileTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("BoardBrowserRow.reconcile")
struct BoardBrowserRowReconcileTests {

    private func remote(_ id: String, _ name: String) -> RemoteBoard {
        RemoteBoard(id: id, name: name, provider: "Fizzy")
    }

    @Test("each of the four cases lands in the right kind, paired first")
    func fourCases() {
        let localPaired = UUID()
        let localOnly = UUID()

        let rows = BoardBrowserRow.reconcile(
            localBoards: [
                .init(id: localPaired, name: "Roadmap"),
                .init(id: localOnly, name: "Personal"),
            ],
            remoteBoards: [
                remote("fz-roadmap", "Roadmap"),
                remote("fz-design", "Design Review"),
            ],
            pairings: [
                FizzyBoardPairing(localBoardID: localPaired, fizzyBoardID: "fz-roadmap",
                                  lastSyncAt: Date(timeIntervalSince1970: 100), syncEnabled: true)
            ]
        )

        #expect(rows.count == 3)
        // Paired row first.
        #expect(rows[0].kind == .paired)
        #expect(rows[0].localBoardID == localPaired)
        #expect(rows[0].fizzyBoardID == "fz-roadmap")
        #expect(rows[0].title == "Roadmap")
        #expect(rows[0].lastSyncAt == Date(timeIntervalSince1970: 100))
        #expect(rows[0].syncEnabled == true)
        // Then local-only.
        #expect(rows[1].kind == .localOnly)
        #expect(rows[1].localBoardID == localOnly)
        #expect(rows[1].title == "Personal")
        // Then remote-only.
        #expect(rows[2].kind == .remoteOnly)
        #expect(rows[2].fizzyBoardID == "fz-design")
        #expect(rows[2].title == "Design Review")
    }

    @Test("paused pairing carries syncEnabled == false")
    func pausedPairing() {
        let id = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [.init(id: id, name: "Archive")],
            remoteBoards: [remote("fz-archive", "Archive")],
            pairings: [FizzyBoardPairing(localBoardID: id, fizzyBoardID: "fz-archive", syncEnabled: false)]
        )
        #expect(rows.count == 1)
        #expect(rows[0].kind == .paired)
        #expect(rows[0].syncEnabled == false)
    }

    @Test("title falls back to cached fizzyBoardName then remote name when local missing")
    func titleFallback() {
        let missingLocal = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [],
            remoteBoards: [remote("fz-x", "Remote Name")],
            pairings: [FizzyBoardPairing(localBoardID: missingLocal, fizzyBoardID: "fz-x",
                                         fizzyBoardName: "Cached Name")]
        )
        #expect(rows[0].title == "Cached Name")
    }

    @Test("ids are stable and unique across kinds")
    func stableIDs() {
        let local = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [.init(id: local, name: "L")],
            remoteBoards: [remote("fz-r", "R")],
            pairings: []
        )
        #expect(rows.first { $0.kind == .localOnly }?.id == local.uuidString)
        #expect(rows.first { $0.kind == .remoteOnly }?.id == "fizzy:fz-r")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/BoardBrowserRowReconcileTests`
Expected: FAIL to build with "cannot find 'BoardBrowserRow' in scope".

- [ ] **Step 3: Implement the row + join**

Create `FenixKanban/Features/Sync/Fizzy/BoardBrowserRow.swift`:

```swift
import Foundation

/// One row in the board browser, reconciling the local `Board` set, the remote
/// board list, and the device-local pairing store (issue #18, Phase 7b).
///
/// A pure value snapshot — it holds no live CoreData object. Display fields are
/// captured at reconcile time so the list is a stateless projection that cannot
/// drift from the stores.
struct BoardBrowserRow: Identifiable, Equatable {

    enum Kind: Equatable {
        case paired       // a pairing exists for this board
        case localOnly    // a local board with no pairing
        case remoteOnly   // a remote board with no pairing
    }

    /// Stable identity: the local board UUID string for paired/local rows,
    /// `"fizzy:<id>"` for remote-only rows.
    let id: String
    let kind: Kind
    let localBoardID: UUID?
    let fizzyBoardID: String?
    let title: String
    let lastSyncAt: Date?
    let syncEnabled: Bool

    /// Minimal local-board projection so the join is unit-testable without
    /// spinning up CoreData.
    struct LocalBoardInfo: Equatable {
        let id: UUID
        let name: String
    }

    /// The reconciliation join (Phase 7b). Returns rows grouped by kind:
    /// paired first (in pairing-store insertion order), then local-only, then
    /// remote-only. A paired row's title prefers the resolved local board name,
    /// then the cached `fizzyBoardName`, then the live remote name.
    static func reconcile(
        localBoards: [LocalBoardInfo],
        remoteBoards: [RemoteBoard],
        pairings: [FizzyBoardPairing]
    ) -> [BoardBrowserRow] {
        let localByID = Dictionary(localBoards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remoteBoards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairedLocalIDs = Set(pairings.map(\.localBoardID))
        let pairedFizzyIDs = Set(pairings.map(\.fizzyBoardID))

        let pairedRows = pairings.map { p in
            BoardBrowserRow(
                id: p.localBoardID.uuidString,
                kind: .paired,
                localBoardID: p.localBoardID,
                fizzyBoardID: p.fizzyBoardID,
                title: localByID[p.localBoardID]?.name
                    ?? p.fizzyBoardName
                    ?? remoteByID[p.fizzyBoardID]?.name
                    ?? "(unknown board)",
                lastSyncAt: p.lastSyncAt,
                syncEnabled: p.syncEnabled
            )
        }

        let localOnlyRows = localBoards
            .filter { !pairedLocalIDs.contains($0.id) }
            .map { l in
                BoardBrowserRow(
                    id: l.id.uuidString,
                    kind: .localOnly,
                    localBoardID: l.id,
                    fizzyBoardID: nil,
                    title: l.name,
                    lastSyncAt: nil,
                    syncEnabled: false
                )
            }

        let remoteOnlyRows = remoteBoards
            .filter { !pairedFizzyIDs.contains($0.id) }
            .map { r in
                BoardBrowserRow(
                    id: "fizzy:\(r.id)",
                    kind: .remoteOnly,
                    localBoardID: nil,
                    fizzyBoardID: r.id,
                    title: r.name,
                    lastSyncAt: nil,
                    syncEnabled: false
                )
            }

        return pairedRows + localOnlyRows + remoteOnlyRows
    }
}
```

- [ ] **Step 4: Regenerate the project and run the test**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/BoardBrowserRowReconcileTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/BoardBrowserRow.swift \
        FenixKanbanTests/Features/Sync/Fizzy/BoardBrowserRowReconcileTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#18): board browser reconciliation join (local + remote + pairings)"
```

---

### Task 3: Browser view model — load / error / refresh

**Files:**
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift`
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift`

**Interfaces:**
- Consumes: `FizzySyncProvider` (`fetchRemoteBoards() async throws -> [RemoteBoard]`, `boardPairingStoreRef.all()`, `persistenceRef.viewContext`); `BoardBrowserRow.reconcile(...)`; the `Harness` test scaffold pattern from `FizzySyncProviderTests` (`MockHTTPState`, `mock.makeSession()`, `FizzyBoardPairingStore(fileURL:)`, `FizzyCardPairingStore(fileURL:)`, `FizzyAuthState(keyPrefix:)`); `BoardRepository`/`CardRepository` for seeding local boards.
- Produces:
  - `final class FizzyBoardBrowserViewModel` (`@Observable @MainActor`) with `init(provider:)`, `enum LoadState: Equatable { case loading, loaded, error(String) }`, `private(set) var state`, `private(set) var rows: [BoardBrowserRow]`, `private(set) var remoteBoards: [RemoteBoard]`, `func load() async`, `func refreshFromStore()`.

- [ ] **Step 1: Write the failing VM load/error test**

Create `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardBrowserViewModel", .serialized)
@MainActor
struct FizzyBoardBrowserViewModelTests {

    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let authState: FizzyAuthState
        let boardPairingStore: FizzyBoardPairingStore
        let pairingStore: FizzyCardPairingStore
        let provider: FizzySyncProvider

        @MainActor
        init() {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            let prefix = "test.fizzy.browser.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            boardPairingStore = FizzyBoardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-board-pairings-\(UUID().uuidString).json"))
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json"))
            provider = FizzySyncProvider(
                authState: authState,
                persistence: persistence,
                urlSession: mock.makeSession(),
                clock: ImmediateClock(),
                boardPairingStore: boardPairingStore,
                pairingStore: pairingStore)
            authState.setAccessToken("tok"); authState.setAccountSlug("ACCT")
        }

        func tearDown() {
            authState.clear()
            try? FileManager.default.removeItem(at: boardPairingStore.fileURL)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
        }

        /// Two remote boards: "fz-A" / "fz-B".
        func stubTwoRemoteBoards() {
            let json = """
            [
              {"id":"fz-A","name":"Alpha","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}},
              {"id":"fz-B","name":"Beta","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
            ]
            """
            mock.handler = { req in
                switch (req.httpMethod, req.url?.path) {
                case ("GET", let p?) where p.hasSuffix("/boards"):
                    return (json.data(using: .utf8)!, .ok(for: req))
                default:
                    return (Data(), .response(for: req, status: 500))
                }
            }
        }
    }

    @Test("load reconciles a paired board, a local-only board, and a remote-only board")
    func loadReconciles() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()

        // One local board paired to fz-A, one local board unpaired.
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        _ = repo.createBoard(name: "Solo")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()

        #expect(model.state == .loaded)
        #expect(model.rows.filter { $0.kind == .paired }.count == 1)
        #expect(model.rows.filter { $0.kind == .localOnly }.count == 1)   // "Solo"
        #expect(model.rows.filter { $0.kind == .remoteOnly }.count == 1)  // fz-B
    }

    @Test("remote failure surfaces .error but still shows cached paired + local rows")
    func loadErrorKeepsCachedRows() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.mock.handler = { req in (Data(), .response(for: req, status: 500)) }

        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()

        if case .error = model.state {} else { Issue.record("expected .error state") }
        #expect(model.rows.contains { $0.kind == .paired })       // cached pairing still rendered
        #expect(model.rows.allSatisfy { $0.kind != .remoteOnly }) // no remote data
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelTests`
Expected: FAIL to build with "cannot find 'FizzyBoardBrowserViewModel' in scope".

- [ ] **Step 3: Implement the view model**

Create `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift`:

```swift
import Foundation
import CoreData
import Observation

/// Drives `FizzyBoardBrowserView` (issue #18, Phase 7b). Loads the three
/// reconciliation inputs — local `Board` set, remote board list, pairing store —
/// and rebuilds `rows` via `BoardBrowserRow.reconcile`. Holds no pairing state
/// of its own; `refreshFromStore()` rebuilds after a local mutation without a
/// network round-trip.
@Observable
@MainActor
final class FizzyBoardBrowserViewModel {

    enum LoadState: Equatable {
        case loading
        case loaded
        case error(String)
    }

    private let provider: FizzySyncProvider

    private(set) var state: LoadState = .loading
    private(set) var rows: [BoardBrowserRow] = []
    private(set) var remoteBoards: [RemoteBoard] = []

    init(provider: FizzySyncProvider) {
        self.provider = provider
    }

    /// Fetches local + remote boards, then rebuilds rows. On remote failure the
    /// state goes `.error` but paired + local-only rows still render from cached
    /// store data (a degraded but useful list).
    func load() async {
        state = .loading
        do {
            remoteBoards = try await provider.fetchRemoteBoards()
            rebuildRows()
            state = .loaded
        } catch {
            remoteBoards = []
            rebuildRows()
            state = .error("\(error)")
        }
    }

    /// Rebuilds rows from the current store + cached remote list, with no
    /// network call — used after toggle / unpair so the UI updates immediately.
    func refreshFromStore() {
        rebuildRows()
    }

    private func rebuildRows() {
        rows = BoardBrowserRow.reconcile(
            localBoards: fetchLocalBoards(),
            remoteBoards: remoteBoards,
            pairings: provider.boardPairingStoreRef.all()
        )
    }

    private func fetchLocalBoards() -> [BoardBrowserRow.LocalBoardInfo] {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        let boards = (try? provider.persistenceRef.viewContext.fetch(request)) ?? []
        return boards.compactMap { b in
            guard let id = b.id else { return nil }
            return BoardBrowserRow.LocalBoardInfo(id: id, name: b.name ?? "(untitled)")
        }
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#18): board browser view model — load/error/refresh"
```

---

### Task 4: Paired-row actions + the browser view

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift` (add action methods)
- Create: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift`
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift` (append an actions suite)

**Interfaces:**
- Consumes: `FizzySyncProvider.setSyncEnabled(localBoardID:_:)`, `.unpair(localBoardID:)`, `.sync(boardId:remoteProjectId:)`, `.boardActivityRef`; `BoardBrowserRow`; `SyncActivityState.Phase`.
- Produces on the VM: `func toggleSync(_ row: BoardBrowserRow)`, `func unpair(_ row: BoardBrowserRow)`, `func syncNow(_ row: BoardBrowserRow) async` — each guards `kind == .paired`, mutates via the provider, then `rebuildRows()`. Produces `struct FizzyBoardBrowserView: View` with `init(provider: FizzySyncProvider)`.

- [ ] **Step 1: Write the failing actions test**

Append to `FizzyBoardBrowserViewModelTests.swift` (inside the same file, a new suite):

```swift
@Suite("FizzyBoardBrowserViewModel actions", .serialized)
@MainActor
struct FizzyBoardBrowserViewModelActionTests {

    @Test("toggleSync flips the paired row's syncEnabled and refreshes")
    func toggleFlipsAndRefreshes() async throws {
        let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()
        let row = try #require(model.rows.first { $0.kind == .paired })
        #expect(row.syncEnabled == true)

        model.toggleSync(row)

        #expect(h.boardPairingStore.pairing(forLocal: alpha.id!)?.syncEnabled == false)
        #expect(model.rows.first { $0.kind == .paired }?.syncEnabled == false)  // row reprojected
    }

    @Test("unpair removes the pairing row and never deletes the local board")
    func unpairKeepsLocalBoard() async throws {
        let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

        let model = FizzyBoardBrowserViewModel(provider: h.provider)
        await model.load()
        let row = try #require(model.rows.first { $0.kind == .paired })

        model.unpair(row)

        #expect(h.boardPairingStore.pairing(forLocal: alpha.id!) == nil)         // pairing gone
        let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
        #expect(boards.contains { $0.id == alpha.id! })                          // board kept
        // Alpha now reconciles as local-only.
        #expect(model.rows.contains { $0.kind == .localOnly && $0.localBoardID == alpha.id! })
    }
}
```

> Note: `Harness`, `stubTwoRemoteBoards()` are reused from Task 3's test struct — make `Harness` and its helpers accessible to the new suite (declare `Harness` at file scope, or `internal`, rather than `private`, so both suites use it). Adjust the Task 3 file accordingly when implementing.

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests`
Expected: FAIL to build with "value of type 'FizzyBoardBrowserViewModel' has no member 'toggleSync'".

- [ ] **Step 3: Add the action methods to the VM**

In `FizzyBoardBrowserViewModel.swift`, add after `refreshFromStore()`:

```swift
    /// Flips `syncEnabled` for a paired row (pause / resume), then reprojects.
    func toggleSync(_ row: BoardBrowserRow) {
        guard row.kind == .paired, let id = row.localBoardID else { return }
        provider.setSyncEnabled(localBoardID: id, !row.syncEnabled)
        rebuildRows()
    }

    /// Removes the pairing for a paired row (never touches `Card` data), then
    /// reprojects — the board reappears as a local-only row.
    func unpair(_ row: BoardBrowserRow) {
        guard row.kind == .paired, let id = row.localBoardID else { return }
        provider.unpair(localBoardID: id)
        rebuildRows()
    }

    /// Runs a one-board sync. Errors are swallowed here; the per-board activity
    /// registry (`provider.boardActivityRef`) records them for the row to show.
    func syncNow(_ row: BoardBrowserRow) async {
        guard row.kind == .paired, let id = row.localBoardID, let fizzyID = row.fizzyBoardID else { return }
        _ = try? await provider.sync(boardId: id, remoteProjectId: fizzyID)
        rebuildRows()
    }
```

- [ ] **Step 4: Run the actions test**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Create the SwiftUI view**

Create `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift`:

```swift
import SwiftUI

/// Unified board browser (issue #18, Phase 7b). Reconciles local + remote
/// boards into one grouped list: Synced, Local only, On Fizzy only. Rows are a
/// pure projection of `FizzyBoardBrowserViewModel.rows` plus the per-board
/// activity registry (`provider.boardActivityRef`).
///
/// Phase 7b scope: paired rows are actionable (pause/resume, Sync Now, unpair).
/// Local-only / on-Fizzy-only rows are display-only; their Create-on-Fizzy /
/// Add-to-FK / Link actions land in Phase 7c.
struct FizzyBoardBrowserView: View {

    let provider: FizzySyncProvider
    @State private var model: FizzyBoardBrowserViewModel
    @State private var rowPendingUnpair: BoardBrowserRow?

    init(provider: FizzySyncProvider) {
        self.provider = provider
        _model = State(initialValue: FizzyBoardBrowserViewModel(provider: provider))
    }

    var body: some View {
        List {
            switch model.state {
            case .loading:
                Section { ProgressView("Loading boards…") }
            case .error(let message):
                Section {
                    SwiftUI.Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                rowSections
            case .loaded:
                rowSections
            }
        }
        .navigationTitle("Fizzy Boards")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog(
            "Unpair this board?",
            isPresented: Binding(
                get: { rowPendingUnpair != nil },
                set: { if !$0 { rowPendingUnpair = nil } }
            ),
            presenting: rowPendingUnpair
        ) { row in
            Button("Unpair", role: .destructive) {
                model.unpair(row)
                rowPendingUnpair = nil
            }
            Button("Cancel", role: .cancel) { rowPendingUnpair = nil }
        } message: { _ in
            Text("Stops syncing this board. Your local cards are kept.")
        }
    }

    @ViewBuilder
    private var rowSections: some View {
        let paired = model.rows.filter { $0.kind == .paired }
        let localOnly = model.rows.filter { $0.kind == .localOnly }
        let remoteOnly = model.rows.filter { $0.kind == .remoteOnly }

        if !paired.isEmpty {
            Section("Synced") { ForEach(paired) { pairedRow($0) } }
        }
        if !localOnly.isEmpty {
            Section("Local only") { ForEach(localOnly) { simpleRow($0, caption: "Not on Fizzy") } }
        }
        if !remoteOnly.isEmpty {
            Section("On Fizzy only") { ForEach(remoteOnly) { simpleRow($0, caption: "Not in FenixKanban") } }
        }
    }

    @ViewBuilder
    private func pairedRow(_ row: BoardBrowserRow) -> some View {
        let phase = row.localBoardID.map { provider.boardActivityRef.phase(for: $0) } ?? .idle
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .foregroundStyle(row.syncEnabled ? .primary : .secondary)
                Spacer()
                trailing(for: phase, row: row)
            }
            if case .error(let msg) = phase {
                Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { rowPendingUnpair = row } label: {
                SwiftUI.Label("Unpair", systemImage: "link.badge.minus")
            }
            Button { Task { await model.syncNow(row) } } label: {
                SwiftUI.Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { Task { await model.syncNow(row) } } label: {
                SwiftUI.Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { model.toggleSync(row) } label: {
                SwiftUI.Label(row.syncEnabled ? "Pause Sync" : "Resume Sync",
                              systemImage: row.syncEnabled ? "pause.circle" : "play.circle")
            }
            Button(role: .destructive) { rowPendingUnpair = row } label: {
                SwiftUI.Label("Unpair", systemImage: "link.badge.minus")
            }
        }
    }

    @ViewBuilder
    private func trailing(for phase: SyncActivityState.Phase, row: BoardBrowserRow) -> some View {
        switch phase {
        case .syncing:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if !row.syncEnabled {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            } else if let last = row.lastSyncAt {
                Text(last, style: .relative).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not synced").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func simpleRow(_ row: BoardBrowserRow, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 6: Regenerate, build, and run the browser tests**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then build (verifies the SwiftUI view compiles): `xcodebuild build -scheme FenixKanban -destination 'generic/platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelTests -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift \
        FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#18): board browser view + paired-row actions (pause/sync/unpair)"
```

---

### Task 5: Mount in Settings + 7a deferred cleanups + full verification

**Files:**
- Modify: `FenixKanban/Features/Sync/SyncSettingsView.swift` (add "Manage Boards" link)
- Modify (doc-comment sweep, behavior-neutral): `FenixKanban/Core/Persistence/ColumnTombstone+CoreDataClass.swift:11`, `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift:24` and `:1037`, `FenixKanban/Features/Sync/.../CardSyncBadgeState.swift:20`, `FenixKanban/Features/Sync/Fizzy/FizzyAuthPhase.swift:4`
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (collapse byte-identical `makeEngine(for:)`)

**Interfaces:**
- Consumes: `FizzyBoardBrowserView(provider:)` (Task 4); `SyncSettingsView`'s existing `registry` + `syncScheduler`; `FizzySyncProvider.isAuthenticated`, `.makeEngine()`.
- Produces: a "Manage Boards" navigation entry in Board Sync settings; no public surface change from the cleanups.

- [ ] **Step 1: Add the "Manage Boards" navigation link**

In `SyncSettingsView.swift`, add a new section after the `Sync Providers` section (before `conflictSection`). Match the existing `registry.providers.first(where:)` idiom already used by `conflictSection`:

```swift
            // Multi-board browser (Phase 7b, issue #18)
            if let fizzy = registry.providers.first(where: { $0 is FizzySyncProvider }) as? FizzySyncProvider,
               fizzy.isAuthenticated {
                Section {
                    NavigationLink {
                        FizzyBoardBrowserView(provider: fizzy)
                    } label: {
                        SwiftUI.Label("Manage Boards", systemImage: "rectangle.stack")
                    }
                } footer: {
                    Text("Browse and pair every board between FenixKanban and Fizzy.")
                }
            }
```

- [ ] **Step 2: Collapse the byte-identical `makeEngine(for:)` (7a deferred minor)**

In `FizzySyncProvider.swift`, replace the duplicated body of `makeEngine(for:)` so it delegates (the board ID is passed through at `engine.sync(localBoardID:)` time, so the engine is board-agnostic to build):

```swift
    /// Builds a `FizzySyncEngine` for a specific local board. The engine is
    /// board-agnostic to construct — the board ID is applied at
    /// `engine.sync(localBoardID:)` call time — so this delegates to
    /// `makeEngine()`. Returns `nil` when unauthenticated.
    func makeEngine(for localBoardID: UUID) -> FizzySyncEngine? {
        makeEngine()
    }
```

- [ ] **Step 3: Sweep the 5 stale `FizzyBoardMapping` doc-comment breadcrumbs (7a deferred minor)**

Each is a comment referencing the retired `FizzyBoardMapping` type. Update the wording to reference `FizzyBoardPairingStore` (or drop the stale clause) — **doc comments only, no code change**. Locate them precisely first:

Run: `grep -rn "FizzyBoardMapping" FenixKanban`
Expected matches: `ColumnTombstone+CoreDataClass.swift`, `FizzySyncEngine.swift` (×2), `CardSyncBadgeState.swift`, `FizzyAuthPhase.swift`. Edit each comment to name `FizzyBoardPairingStore` instead, preserving the surrounding sentence. After editing, re-run the grep:

Run: `grep -rn "FizzyBoardMapping" FenixKanban`
Expected: no matches in source (only this plan / spec under `docs/` may still mention it).

- [ ] **Step 4: Regenerate, run the FULL suite, and build macOS**

Run: `make generate && git add FenixKanban.xcodeproj/project.pbxproj`
Then: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests`
Expected: `** TEST SUCCEEDED **`, 0 failures.
Then: `xcodebuild build -scheme FenixKanban -destination 'generic/platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/SyncSettingsView.swift \
        FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanban/Core/Persistence/ColumnTombstone+CoreDataClass.swift \
        FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanban.xcodeproj/project.pbxproj
# plus the CardSyncBadgeState + FizzyAuthPhase files at their real paths (from Step 3's grep)
git commit -m "feat(#18): mount board browser in Settings; retire FizzyBoardMapping breadcrumbs"
```

> The exact paths for `CardSyncBadgeState.swift` and `FizzyAuthPhase.swift` come from Step 3's `grep` output — stage them by explicit path alongside the others.

---

## Self-Review

**1. Spec coverage** (Phase 7b section of the design):
- Unified reconciliation list (Synced / Local only / On Fizzy only) → Task 2 (join) + Task 4 (view). ✅
- Reconciliation rule (pairing → paired; local w/o pairing → local-only; remote w/o pairing → remote-only) → Task 2 `reconcile`, tested four ways. ✅
- Per-row actions: sync toggle (`syncEnabled`), Sync Now (one-board `provider.sync`), pause, unpair (never touches `Card`) → Task 4 VM methods + view, tested. ✅
- Error rows expand to the message → Task 4 `pairedRow` shows `.error(msg)`; per-board source is the Task 1 registry. ✅
- State source: pure projection of pairing store + per-board activity map (Phase 6 `SyncActivityState` shape, keyed by board) → Task 1 `FizzyBoardSyncActivity` + Task 2/3 projection. ✅
- Shared by Settings **and onboarding** / Create-Add-Link buttons → **explicitly deferred to 7c** (see Scope & deviations). Documented, not silently dropped. ✅
- Testing (7b row): four reconciliation cases; toggle/pause/unpair mutate the store and never touch `Card`; rows are a pure projection → Tasks 2 & 4 tests. ✅

**2. Placeholder scan:** No TBD/TODO. Every code step shows complete, compilable code. The two implementer notes (reuse `Harness` across suites; pull exact cleanup paths from `grep`) point at concrete existing patterns, not unspecified logic.

**3. Type consistency:** `BoardBrowserRow` fields and `Kind` cases are identical across Tasks 2/3/4. `FizzyBoardSyncActivity` method names (`phase(for:)`, `markSyncing/Idle/Error`) match Task 1's definition and Task 4's use. VM surface (`state`, `rows`, `remoteBoards`, `load()`, `refreshFromStore()`, `toggleSync/unpair/syncNow`) is consistent Tasks 3→4. Provider members consumed (`fetchRemoteBoards`, `boardPairingStoreRef.all()`, `persistenceRef.viewContext`, `setSyncEnabled`, `unpair`, `sync(boardId:remoteProjectId:)`, `boardActivityRef`) all match the verified 7a surface. `SyncActivityState.Phase` reused verbatim.

## Execution Handoff

Phase 7b's design is already approved in the 7a spec, so this plan is ready to execute task-by-task. Recommended: **subagent-driven-development** (fresh implementer per task + task review + final whole-branch review). Note: this plan builds on the Phase 7a interfaces currently on `claude/18-multi-board-pairing` (PR #60, open against `develop`) — execute on a branch that includes those commits (branch off the 7a branch, or off `develop` once #60 merges).
