# Multi-board pairing — Phase 7c (Create / Pull / Link flows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user turn an unpaired board into a synced pairing from the board browser — three flows: **Create on Fizzy** (local→new remote, push), **Add to FK** (remote→new local, replace-pull), and **Link existing** (existing↔existing, merge) — completing issue #18 Phase 7.

**Architecture:** Three new orchestration methods on `FizzySyncProvider` each *upsert a pairing then run the matching first-sync mode*, returning the `FizzySyncResult`. `FizzyBoardBrowserViewModel` gains thin async actions that call them, refresh rows from the store, and surface results/errors. `FizzyBoardBrowserView` adds per-row buttons to the "Local only" / "On Fizzy only" sections plus a Link picker sheet and a merge result/error alert. Strictly additive — the 7b paired-row behavior and the single-pair `FizzyAuthView` flow are untouched.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), CoreData, `@Observable @MainActor`, XcodeGen.

## Global Constraints

- Tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`). Any suite that calls CoreData `context.save()` must be `@MainActor`.
- View models are `@Observable @MainActor` (the Observation macro), **never** `ObservableObject`.
- No new `.swift` file is added in 7c **except** none is expected — all changes extend existing files. **If** a file is added/removed, run `make generate` from the repo root, then stage `FenixKanban.xcodeproj/project.pbxproj` by its explicit path. **Never** `git add -A` / `git add .` — stage every path explicitly.
- No `Co-Authored-By` trailer on commits.
- SwiftUI must compile for **iOS and macOS** — run the macOS build for any view-touching task.
- The iOS simulator intermittently crashes (`FBSOpenApplicationServiceErrorDomain Code=3`); if a run fails on launch (not on an assertion), retry the same command once or twice — environmental.

## Verified interfaces (current `claude/18-multi-board-pairing` tip)

- `FizzySyncProvider` (internal): `makeClient() -> FizzyClient?`, `makeEngine(for: UUID) -> FizzySyncEngine?`, `fetchRemoteBoards() async throws -> [RemoteBoard]`, `pair(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?)`, `unpair(localBoardID:)`, `setSyncEnabled(localBoardID:_:)`, `sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult`, `boardPairingStoreRef: FizzyBoardPairingStore`, `boardActivityRef`, `persistenceRef: PersistenceController`, `authStateRef`. **`createRemoteTwin` / `addToFK` / `linkExisting` do NOT exist — this phase creates them.**
- `FizzyClient.createBoard(_ board: FizzyBoardWrite) async throws -> FizzyBoardDetail`. `FizzyBoardWrite(name: String? = nil)`. `FizzyBoardDetail.id: String`, `.name: String`.
- `FizzySyncEngine.syncFirst(localBoardID: UUID, mode: FirstSyncMode) async throws -> FizzySyncResult` (`@MainActor`). Returns empty `FizzySyncResult()` (no throw) when unauthenticated / no pairing / no local board.
- `FirstSyncMode { pushLocalToFizzy, replaceLocalWithFizzy, mergeIfNoConflicts }`.
- `FizzySyncResult { var itemsCreated/Updated/Deleted: Int; var errors: [String]; var conflicts: [ConflictRecord]; mutating func merge(_:) }`. **Merge-mode title collisions are appended to `.errors` as `"Same-title collision: '<title>'"`; they are NOT written to `FizzyConflictStore` by `syncFirst`.**
- `FizzyError.unauthorized` exists.
- `BoardRepository(context: NSManagedObjectContext).createBoard(name: String, colorHex: String? = nil) -> Board` — sets `id = UUID()`, computes `sortOrder`, saves. `board.id` is `UUID?` (CoreData-optional, populated).
- `FizzyBoardPairingStore.pairing(forFizzy: String) -> FizzyBoardPairing?`, `.pairing(forLocal: UUID) -> FizzyBoardPairing?`, `.all() -> [FizzyBoardPairing]`.
- `FizzyBoardBrowserViewModel` (`@Observable @MainActor`): `init(provider:)`, `private(set) var state: LoadState`, `private(set) var rows: [BoardBrowserRow]`, `private(set) var remoteBoards: [RemoteBoard]`, `load() async`, `refreshFromStore()`, `toggleSync/unpair`, `syncNow(_:) async`, private `rebuildRows()` / `fetchLocalBoards()`.
- `BoardBrowserRow { let id: String; let kind: Kind{paired,localOnly,remoteOnly}; let localBoardID: UUID?; let fizzyBoardID: String?; let title: String; let lastSyncAt: Date?; let syncEnabled: Bool }`.
- Test `Harness` is **internal** in `FizzyBoardBrowserViewModelTests` (reusable): `mock`, `persistence`, `authState`, `boardPairingStore`, `pairingStore`, `provider`, `tearDown()`, `stubTwoRemoteBoards()`. `MockHTTPState` factories: `.ok(for:)`, `.response(for:status:headers:)`. `ImmediateClock()`.

## Scope & deviations (read before Task 1)

- **Onboarding promotion is deferred (not in 7c).** The 7a design called for the browser to be shared by Settings *and* onboarding, but **no onboarding/first-launch host exists** in the app (the only first-run gate is Sign in with Apple). Building one is net-new scope; 7c stays additive in Settings, consistent with 7b. Tracked as a follow-up.
- **Merge conflicts surface via `result.errors`, not the conflict store.** The spec text said "Link existing… surfaces the conflict store," but `syncFirst(mode: .mergeIfNoConflicts)` reports same-title collisions in `FizzySyncResult.errors` and does not write `FizzyConflictStore`. 7c surfaces those error strings to the user in an alert. (Steady-state `sync()` still populates the conflict store for ongoing LWW conflicts — unchanged.)
- **Create on Fizzy uses the local board's name** as the new remote board name (no rename prompt — YAGNI). The local-only row title *is* the board name.
- **Engine first-sync behavior is already engine-tested.** 7c provider/VM tests assert the *7c-specific* side effects — remote board POSTed, local board created, pairing upserted, action completes without throwing — using empty boards so first-sync is a near-noop. The per-mode pull/push/merge semantics are covered by existing `FizzySyncEngine*Tests` / `FirstSyncModeTests`; 7c does not re-test them.
- **Folds in the three deferred 7b Minors** (Task 5): prune the activity registry on unpair; decide/guard `syncNow` on a paused board; drop the no-op `url.path as String?` cast.

---

### Task 1: Provider — `createRemoteTwin` + `addToFK` (low-risk push / replace flows)

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (add two methods in the `// MARK: - Per-board routing` region)
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserOrchestrationTests.swift` (new)

**Interfaces:**
- Consumes: `makeClient()`, `createBoard(_:)`, `pair(...)`, `makeEngine(for:)`, `syncFirst(localBoardID:mode:)`, `BoardRepository.createBoard(name:)`.
- Produces (later tasks rely on these exact signatures):
  - `func createRemoteTwin(localBoardID: UUID, name: String) async throws -> FizzySyncResult`
  - `func addToFK(fizzyBoardID: String, name: String) async throws -> UUID` (returns the new local board id)

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserOrchestrationTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardBrowser orchestration", .serialized)
@MainActor
struct FizzyBoardBrowserOrchestrationTests {

    typealias Harness = FizzyBoardBrowserViewModelTests.Harness

    /// Stubs board creation (POST → 201+Location, GET detail) and makes every
    /// other GET return an empty JSON array and every write a 201 — so a
    /// first-sync over an empty board completes without throwing.
    static func stubCreateAndEmptySync(_ mock: MockHTTPState, newID: String, name: String) {
        let detail = """
        {"id":"\(newID)","name":"\(name)","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
        """
        mock.handler = { req in
            let path = req.url?.path ?? ""
            switch req.httpMethod {
            case "POST" where path.hasSuffix("/boards"):
                return (Data(), .response(for: req, status: 201,
                    headers: ["Location": "https://example.com/ACCT/boards/\(newID)"]))
            case "GET" where path.hasSuffix("/boards/\(newID)"):
                return (detail.data(using: .utf8)!, .ok(for: req))
            case "GET":
                return ("[]".data(using: .utf8)!, .ok(for: req))   // list / columns / cards
            default:
                return ("{}".data(using: .utf8)!, .response(for: req, status: 201))
            }
        }
    }

    @Test("createRemoteTwin POSTs a board, caches the name, and upserts a pairing")
    func createRemoteTwinPairs() async throws {
        let h = Harness(); defer { h.tearDown() }
        Self.stubCreateAndEmptySync(h.mock, newID: "fz-NEW", name: "Personal")

        let repo = BoardRepository(context: h.persistence.viewContext)
        let local = repo.createBoard(name: "Personal")
        try h.persistence.viewContext.save()

        _ = try await h.provider.createRemoteTwin(localBoardID: local.id!, name: "Personal")

        let pairing = try #require(h.boardPairingStore.pairing(forLocal: local.id!))
        #expect(pairing.fizzyBoardID == "fz-NEW")
        #expect(pairing.fizzyBoardName == "Personal")
        #expect(h.mock.requests.contains { $0.httpMethod == "POST" && ($0.url?.path.hasSuffix("/boards") ?? false) })
    }

    @Test("addToFK creates a local board, returns its id, and upserts a pairing")
    func addToFKCreatesLocalBoard() async throws {
        let h = Harness(); defer { h.tearDown() }
        Self.stubCreateAndEmptySync(h.mock, newID: "unused", name: "Design Review")

        let newLocalID = try await h.provider.addToFK(fizzyBoardID: "fz-REMOTE", name: "Design Review")

        let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
        #expect(boards.contains { $0.id == newLocalID && $0.name == "Design Review" })
        let pairing = try #require(h.boardPairingStore.pairing(forLocal: newLocalID))
        #expect(pairing.fizzyBoardID == "fz-REMOTE")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserOrchestrationTests 2>&1 | tail -40`
Expected: FAIL — `value of type 'FizzySyncProvider' has no member 'createRemoteTwin'` (and `addToFK`).

- [ ] **Step 3: Implement the two methods**

In `FizzySyncProvider.swift`, in the `// MARK: - Per-board routing` region (next to `pair`/`unpair`), add:

```swift
/// Create-on-Fizzy (issue #18, Phase 7c): make a new remote board, pair the
/// given local board to it, then first-sync **push** (local is source of
/// truth; the remote starts empty). Returns the first-sync result.
func createRemoteTwin(localBoardID: UUID, name: String) async throws -> FizzySyncResult {
    guard let client = makeClient() else { throw FizzyError.unauthorized }
    let created = try await client.createBoard(FizzyBoardWrite(name: name))
    pair(localBoardID: localBoardID, fizzyBoardID: created.id, fizzyBoardName: created.name)
    guard let engine = makeEngine(for: localBoardID) else { return FizzySyncResult() }
    return try await engine.syncFirst(localBoardID: localBoardID, mode: .pushLocalToFizzy)
}

/// Add-to-FK (issue #18, Phase 7c): create a new local board from a remote
/// board's name, pair it, then first-sync **replace** (remote is source of
/// truth; the local board was just created empty). Returns the new local id.
@discardableResult
func addToFK(fizzyBoardID: String, name: String) async throws -> UUID {
    let board = BoardRepository(context: persistence.viewContext).createBoard(name: name)
    guard let localBoardID = board.id else { throw FizzyError.unexpectedStatus(0) }
    pair(localBoardID: localBoardID, fizzyBoardID: fizzyBoardID, fizzyBoardName: name)
    if let engine = makeEngine(for: localBoardID) {
        _ = try await engine.syncFirst(localBoardID: localBoardID, mode: .replaceLocalWithFizzy)
    }
    return localBoardID
}
```

> `persistence` is the provider's private stored property (the test confirms via `persistenceRef`). `BoardRepository.createBoard` saves the context itself.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserOrchestrationTests 2>&1 | tail -40`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
make generate
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserOrchestrationTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#18): provider create-remote-twin + add-to-FK pairing flows"
```

---

### Task 2: Provider — `linkExisting` (merge flow)

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift`
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserOrchestrationTests.swift` (extend)

**Interfaces:**
- Produces: `func linkExisting(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?) async throws -> FizzySyncResult`

- [ ] **Step 1: Write the failing test**

Append to `FizzyBoardBrowserOrchestrationTests`:

```swift
@Test("linkExisting pairs the two boards and runs a merge first-sync")
func linkExistingPairsAndMerges() async throws {
    let h = Harness(); defer { h.tearDown() }
    Self.stubCreateAndEmptySync(h.mock, newID: "unused", name: "n/a")

    let repo = BoardRepository(context: h.persistence.viewContext)
    let local = repo.createBoard(name: "Roadmap")
    try h.persistence.viewContext.save()

    let result = try await h.provider.linkExisting(
        localBoardID: local.id!, fizzyBoardID: "fz-RDMP", fizzyBoardName: "Roadmap (Fizzy)")

    let pairing = try #require(h.boardPairingStore.pairing(forLocal: local.id!))
    #expect(pairing.fizzyBoardID == "fz-RDMP")
    #expect(pairing.fizzyBoardName == "Roadmap (Fizzy)")
    // Empty boards → merge produces no collision errors.
    #expect(result.errors.isEmpty)
}
```

> Collision *detection* in merge mode is covered by `FirstSyncModeTests` / `FizzySyncEngineConflictTests`; this test only verifies the 7c wiring (pair + invoke merge + return the result).

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserOrchestrationTests/linkExistingPairsAndMerges 2>&1 | tail -40`
Expected: FAIL — no member `linkExisting`.

- [ ] **Step 3: Implement**

In `FizzySyncProvider.swift`, beside `createRemoteTwin`:

```swift
/// Link-existing (issue #18, Phase 7c): pair two boards that both already
/// have content, then first-sync **merge** (push local-only + pull
/// Fizzy-only; same-title collisions are returned in `result.errors`, not
/// applied). The riskiest flow — the UI warns and confirms before calling.
func linkExisting(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?) async throws -> FizzySyncResult {
    pair(localBoardID: localBoardID, fizzyBoardID: fizzyBoardID, fizzyBoardName: fizzyBoardName)
    guard let engine = makeEngine(for: localBoardID) else { return FizzySyncResult() }
    return try await engine.syncFirst(localBoardID: localBoardID, mode: .mergeIfNoConflicts)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserOrchestrationTests 2>&1 | tail -40`
Expected: PASS (3/3 in the suite).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserOrchestrationTests.swift
git commit -m "feat(#18): provider link-existing merge pairing flow"
```

---

### Task 3: View model — create / add / link actions + Link picker source + result surfacing

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift`
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift` (extend the actions suite)

**Interfaces:**
- Consumes: `provider.createRemoteTwin`, `provider.addToFK`, `provider.linkExisting`, `provider.boardPairingStoreRef.pairing(forFizzy:)`.
- Produces (the view relies on these):
  - `var unpairedRemoteBoards: [RemoteBoard]` (computed)
  - `private(set) var actionError: String?`
  - `private(set) var lastLinkCollisions: [String]?`
  - `func createOnFizzy(_ row: BoardBrowserRow) async`
  - `func addToFK(_ row: BoardBrowserRow) async`
  - `func linkExisting(_ localRow: BoardBrowserRow, toFizzyBoardID: String, fizzyBoardName: String?) async`
  - `func dismissActionError()`, `func dismissLinkCollisions()`

- [ ] **Step 1: Write the failing tests**

Append to `FizzyBoardBrowserViewModelActionTests` in `FizzyBoardBrowserViewModelTests.swift`:

```swift
@Test("createOnFizzy pairs the local-only row and it reprojects as paired")
func createOnFizzyPairs() async throws {
    let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
    FizzyBoardBrowserOrchestrationTests.stubCreateAndEmptySync(h.mock, newID: "fz-NEW", name: "Personal")
    let repo = BoardRepository(context: h.persistence.viewContext)
    let local = repo.createBoard(name: "Personal")
    try h.persistence.viewContext.save()

    let model = FizzyBoardBrowserViewModel(provider: h.provider)
    model.seedRemoteBoardsForTesting([])           // no remote list; local-only row present
    model.refreshFromStore()
    let row = try #require(model.rows.first { $0.kind == .localOnly })

    await model.createOnFizzy(row)

    #expect(h.boardPairingStore.pairing(forLocal: local.id!)?.fizzyBoardID == "fz-NEW")
    #expect(model.rows.contains { $0.kind == .paired && $0.localBoardID == local.id! })
    #expect(model.actionError == nil)
}

@Test("addToFK creates a local board and the remote-only row becomes paired")
func addToFKPairs() async throws {
    let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
    FizzyBoardBrowserOrchestrationTests.stubCreateAndEmptySync(h.mock, newID: "unused", name: "Design")
    let model = FizzyBoardBrowserViewModel(provider: h.provider)
    let remote = RemoteBoard(id: "fz-DSGN", name: "Design", provider: "fizzy")
    model.seedRemoteBoardsForTesting([remote])
    model.refreshFromStore()
    let row = try #require(model.rows.first { $0.kind == .remoteOnly })

    await model.addToFK(row)

    let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
    #expect(boards.contains { $0.name == "Design" })
    #expect(model.rows.contains { $0.kind == .paired })
}

@Test("unpairedRemoteBoards excludes already-paired remote boards")
func unpairedRemoteBoardsFiltersPaired() async throws {
    let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
    let repo = BoardRepository(context: h.persistence.viewContext)
    let alpha = repo.createBoard(name: "Alpha")
    try h.persistence.viewContext.save()
    h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A"))

    let model = FizzyBoardBrowserViewModel(provider: h.provider)
    model.seedRemoteBoardsForTesting([
        RemoteBoard(id: "fz-A", name: "Alpha", provider: "fizzy"),
        RemoteBoard(id: "fz-B", name: "Beta", provider: "fizzy"),
    ])

    #expect(model.unpairedRemoteBoards.map(\.id) == ["fz-B"])
}
```

> `seedRemoteBoardsForTesting(_:)` is a tiny internal test seam (below) that sets the private `remoteBoards` without a network round-trip — `RemoteBoard` is constructed directly so the reconcile/filter logic is driven deterministically.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests 2>&1 | tail -40`
Expected: FAIL — no members `createOnFizzy` / `addToFK` / `unpairedRemoteBoards` / `seedRemoteBoardsForTesting`.

- [ ] **Step 3: Implement the actions**

In `FizzyBoardBrowserViewModel.swift`, add published state next to `remoteBoards`:

```swift
    private(set) var actionError: String?
    private(set) var lastLinkCollisions: [String]?
```

Add the computed picker source and a test seam after `init`:

```swift
    /// Remote boards with no pairing yet — the candidates a "Local only" board
    /// can link to. Drives the Link picker.
    var unpairedRemoteBoards: [RemoteBoard] {
        remoteBoards.filter { provider.boardPairingStoreRef.pairing(forFizzy: $0.id) == nil }
    }

    /// Test seam: set the cached remote list without a network fetch.
    func seedRemoteBoardsForTesting(_ boards: [RemoteBoard]) { remoteBoards = boards }
```

Add the three actions after `syncNow`:

```swift
    /// Create-on-Fizzy: make a remote twin of a local-only board (named after
    /// the local board) and push. Reprojects to a paired row on success.
    func createOnFizzy(_ row: BoardBrowserRow) async {
        guard row.kind == .localOnly, let id = row.localBoardID else { return }
        do {
            _ = try await provider.createRemoteTwin(localBoardID: id, name: row.title)
        } catch {
            actionError = "Couldn't create the board on Fizzy: \(error)"
        }
        rebuildRows()
    }

    /// Add-to-FK: create a local board from a remote-only board and replace-pull.
    func addToFK(_ row: BoardBrowserRow) async {
        guard row.kind == .remoteOnly, let fizzyID = row.fizzyBoardID else { return }
        do {
            _ = try await provider.addToFK(fizzyBoardID: fizzyID, name: row.title)
        } catch {
            actionError = "Couldn't add the board to FenixKanban: \(error)"
        }
        rebuildRows()
    }

    /// Link-existing: merge a local-only board with a chosen unpaired remote
    /// board. Same-title collisions (returned in `result.errors`) are exposed
    /// via `lastLinkCollisions` for the view to show.
    func linkExisting(_ localRow: BoardBrowserRow, toFizzyBoardID fizzyID: String, fizzyBoardName: String?) async {
        guard localRow.kind == .localOnly, let id = localRow.localBoardID else { return }
        do {
            let result = try await provider.linkExisting(
                localBoardID: id, fizzyBoardID: fizzyID, fizzyBoardName: fizzyBoardName)
            if !result.errors.isEmpty { lastLinkCollisions = result.errors }
        } catch {
            actionError = "Couldn't link the boards: \(error)"
        }
        rebuildRows()
    }

    func dismissActionError() { actionError = nil }
    func dismissLinkCollisions() { lastLinkCollisions = nil }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests 2>&1 | tail -40`
Expected: PASS (all action tests, including the prior 7b ones).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift
git commit -m "feat(#18): browser view-model create/add/link actions + link picker source"
```

---

### Task 4: View — row buttons, Link picker sheet, merge result alert

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift`

**Interfaces:**
- Consumes: `model.createOnFizzy/addToFK/linkExisting`, `model.unpairedRemoteBoards`, `model.actionError`, `model.lastLinkCollisions`, `model.dismissActionError/dismissLinkCollisions`.

This task is exercised by the macOS build plus the Task 3 logic tests (the view is a thin shell over the tested view model). No new unit test file.

- [ ] **Step 1: Replace the display-only rows with actionable rows**

In `FizzyBoardBrowserView.swift`, add sheet/alert state next to `rowPendingUnpair`:

```swift
    @State private var linkSourceRow: BoardBrowserRow?
```

Replace the two `simpleRow(...)` call sites in `rowSections` with dedicated builders:

```swift
        if !localOnly.isEmpty {
            Section("Local only") { ForEach(localOnly) { localOnlyRow($0) } }
        }
        if !remoteOnly.isEmpty {
            Section("On Fizzy only") { ForEach(remoteOnly) { remoteOnlyRow($0) } }
        }
```

Replace `simpleRow(_:caption:)` with these two builders:

```swift
    @ViewBuilder
    private func localOnlyRow(_ row: BoardBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text("Not on Fizzy").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { Task { await model.createOnFizzy(row) } } label: {
                    SwiftUI.Label("Create on Fizzy", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                if !model.unpairedRemoteBoards.isEmpty {
                    Button { linkSourceRow = row } label: {
                        SwiftUI.Label("Link…", systemImage: "link")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func remoteOnlyRow(_ row: BoardBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text("Not in FenixKanban").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.addToFK(row) } } label: {
                SwiftUI.Label("Add to FenixKanban", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
```

- [ ] **Step 2: Add the Link picker sheet + alerts**

Append these modifiers to the `List` in `body` (after the existing `.confirmationDialog`):

```swift
        .sheet(item: $linkSourceRow) { localRow in
            LinkBoardSheet(
                localBoardName: localRow.title,
                candidates: model.unpairedRemoteBoards,
                onLink: { remote in
                    linkSourceRow = nil
                    Task { await model.linkExisting(localRow, toFizzyBoardID: remote.id, fizzyBoardName: remote.name) }
                },
                onCancel: { linkSourceRow = nil }
            )
        }
        .alert("Sync problem", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.dismissActionError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Merged with collisions", isPresented: Binding(
            get: { model.lastLinkCollisions != nil },
            set: { if !$0 { model.dismissLinkCollisions() } }
        )) {
            Button("OK", role: .cancel) { model.dismissLinkCollisions() }
        } message: {
            Text((model.lastLinkCollisions ?? []).prefix(8).joined(separator: "\n"))
        }
```

- [ ] **Step 3: Add the `LinkBoardSheet` subview**

At the bottom of `FizzyBoardBrowserView.swift` (file scope, below the struct):

```swift
/// Merge-warning picker for "Link existing ↔ existing" (issue #18, Phase 7c).
/// Lists unpaired remote boards; choosing one runs a **merge** first-sync.
private struct LinkBoardSheet: View {
    let localBoardName: String
    let candidates: [RemoteBoard]
    let onLink: (RemoteBoard) -> Void
    let onCancel: () -> Void

    @State private var picked: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fizzy board", selection: $picked) {
                        Text("Choose…").tag(String?.none)
                        ForEach(candidates) { board in
                            Text(board.name).tag(board.id as String?)
                        }
                    }
                } header: {
                    Text("Link “\(localBoardName)” to")
                } footer: {
                    Text("Merges both boards: local-only and Fizzy-only cards are combined. Same-title cards are reported and skipped, not overwritten. Try the Sandbox board first.")
                        .foregroundStyle(.orange)
                }
                Section {
                    Button("Link & Merge") {
                        if let id = picked, let board = candidates.first(where: { $0.id == id }) {
                            onLink(board)
                        }
                    }
                    .disabled(picked == nil)
                }
            }
            .navigationTitle("Link Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
```

Update the type's header doc-comment (lines 8-10) to reflect that 7c landed:

```swift
/// Phase 7b: paired rows are actionable (pause/resume, Sync Now, unpair).
/// Phase 7c: local-only rows offer Create-on-Fizzy + Link; on-Fizzy-only rows
/// offer Add-to-FK. The single-pair `FizzyAuthView` flow is unchanged.
```

- [ ] **Step 4: Build for both platforms**

Run: `xcodebuild build -scheme FenixKanban -destination 'generic/platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`
Run: `xcodebuild build -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift
git commit -m "feat(#18): browser create/add/link row actions + merge link sheet"
```

---

### Task 5: Fold in deferred 7b Minors + full-suite verification

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (prune registry on unpair)
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift` (guard `syncNow` on paused)
- Modify: `FenixKanbanTests/.../FizzyBoardActivityProviderTests.swift` (drop the no-op cast — locate by the `url.path as String?` text)
- Test: extend `FizzyBoardBrowserViewModelActionTests` for the paused-`syncNow` guard

**Interfaces:** none new.

- [ ] **Step 1: Write the failing test for the paused-syncNow guard**

Append to `FizzyBoardBrowserViewModelActionTests`:

```swift
@Test("syncNow is a no-op on a paused board (does not issue a network sync)")
func syncNowSkipsPausedBoard() async throws {
    let h = FizzyBoardBrowserViewModelTests.Harness(); defer { h.tearDown() }
    h.stubTwoRemoteBoards()
    let repo = BoardRepository(context: h.persistence.viewContext)
    let alpha = repo.createBoard(name: "Alpha")
    try h.persistence.viewContext.save()
    h.boardPairingStore.upsert(FizzyBoardPairing(localBoardID: alpha.id!, fizzyBoardID: "fz-A", syncEnabled: false))

    let model = FizzyBoardBrowserViewModel(provider: h.provider)
    await model.load()
    let row = try #require(model.rows.first { $0.kind == .paired })
    h.mock.requests.removeAll()

    await model.syncNow(row)

    #expect(h.mock.requests.isEmpty)   // paused → no sync issued
}
```

> Confirm `FizzyBoardPairing` exposes a `syncEnabled:` init parameter (the spec lists `syncEnabled: Bool` with default true). If the initializer differs, set it via `setSyncEnabled` after `upsert` instead.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests/syncNowSkipsPausedBoard 2>&1 | tail -40`
Expected: FAIL — a sync request is issued for the paused board.

- [ ] **Step 3: Apply the three fixes**

(a) Guard `syncNow` in `FizzyBoardBrowserViewModel.swift`:

```swift
    func syncNow(_ row: BoardBrowserRow) async {
        guard row.kind == .paired, row.syncEnabled,
              let id = row.localBoardID, let fizzyID = row.fizzyBoardID else { return }
        _ = try? await provider.sync(boardId: id, remoteProjectId: fizzyID)
        rebuildRows()
    }
```

(b) Prune the per-board activity registry when a pairing is removed, in `FizzySyncProvider.unpair(localBoardID:)` — add as the last line of the method body so a stale `.error` can't resurface if the board is re-paired in the same session:

```swift
        boardActivity.markIdle(localBoardID)
```

(c) In `FizzyBoardActivityProviderTests.swift`, find the `guard let path = req.url?.path as String?` (the no-op upcast — `URL.path` is non-optional) and simplify to use `req.url?.path` directly without the `as String?` cast and redundant `guard`. Comment-and-logic-equivalent; just removes the dead optional.

- [ ] **Step 4: Run the full Phase-7 suite + both builds**

Run:
```bash
xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelTests \
  -only-testing:FenixKanbanTests/FizzyBoardBrowserViewModelActionTests \
  -only-testing:FenixKanbanTests/FizzyBoardBrowserOrchestrationTests \
  -only-testing:FenixKanbanTests/BoardBrowserRowReconcileTests \
  -only-testing:FenixKanbanTests/FizzyBoardSyncActivityTests \
  -only-testing:FenixKanbanTests/FizzySyncProviderTests \
  -only-testing:FenixKanbanTests/FizzyMultiBoardSchedulerTests 2>&1 | tail -40
```
Expected: all suites pass.
Run: `xcodebuild build -scheme FenixKanban -destination 'generic/platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserViewModel.swift \
        FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardBrowserViewModelTests.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzyBoardActivityProviderTests.swift
git commit -m "fix(#18): prune activity on unpair, skip paused syncNow, drop dead cast"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-26-multi-board-pairing-design.md` §"Phase 7c"):
- "Create on fizzy → createBoard → upsert pairing → first-sync pushLocalToFizzy" → Task 1 `createRemoteTwin`. ✅
- "Add to FK → create local Board → upsert pairing → first-sync replaceLocalWithFizzy" → Task 1 `addToFK`. ✅
- "Link existing ↔ existing → picker of unpaired remote boards → first-sync mergeIfNoConflicts → confirm sheet, merge warns" → Task 2 `linkExisting` + Task 4 `LinkBoardSheet`. ✅
- "Paths 1 and 2 need no mode picker; only path 3 warns" → Create/Add are single buttons; Link is the only one with a warning sheet. ✅
- "Steered to the Sandbox board for experimentation" → sheet footer copy. ✅
- Testing §7c (each flow pairs + runs the correct first-sync mode; merge surfaces collisions) → Tasks 1–3 assert pairing + completion; merge collisions surfaced via `lastLinkCollisions`; per-mode engine semantics covered by existing engine tests (documented deviation). ✅

**Placeholder scan:** none — every step carries full code or an exact command.

**Type consistency:** `createRemoteTwin(localBoardID:name:)→FizzySyncResult`, `addToFK(fizzyBoardID:name:)→UUID`, `linkExisting(localBoardID:fizzyBoardID:fizzyBoardName:)→FizzySyncResult` are used identically in Tasks 1–3. VM exposes `unpairedRemoteBoards`, `actionError`, `lastLinkCollisions`, `createOnFizzy`/`addToFK`/`linkExisting` consumed verbatim by Task 4. `RemoteBoard(id:name:provider:)` matches the verified initializer. `FizzySyncResult.errors` is `[String]`.

**Open verification for the implementer (flagged, not blocking):**
- `FizzyError.unexpectedStatus(Int)` is used as the "board has no id" throw in `addToFK` — confirm the case exists (the error map lists it). If not, substitute any existing `FizzyError` case.
- `FizzyBoardPairing(localBoardID:fizzyBoardID:syncEnabled:)` initializer shape (Task 5 test) — if `syncEnabled` isn't an init param, call `setSyncEnabled` after `upsert`.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-26-18-multi-board-pairing-7c-create-pull-link.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, spec+quality review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
