# Issue #19 Wave 3: Watch / Pin / Golden toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paired cards get watch and pin toggles (detail view) with small card-face indicators, and golden toggles finally push to Fizzy instead of silently reverting on the next pull.

**Architecture:** All six client endpoints already exist (`watchCard`/`unwatchCard`, `pinCard`/`unpinCard`, `markCardGolden`/`unmarkCardGolden`, plus `myPins()` → `GET /my/pins`). CoreData v8 adds two additive Booleans (`isWatched`, `isPinned`). **Captain's rulings:** watch state is a **local write-only flag** (Fizzy accepts watch/unwatch but never reports current state — no wire field, no watchers endpoint); pin state is **sync-reconciled from `GET /my/pins`** (remote-authoritative, account-scoped). Golden stays local-first (works unpaired) and gains a push for paired cards — fixing the latent bug where `applyRemote`'s `card.isGolden = remote.golden` reverts any local-only golden flip. Toggles mirror the `toggleAssignment` optimistic + state-recheck-revert pattern. Watch/pin flag writes deliberately do NOT bump `modifiedAt` (not part of the card-content LWW contract; bumping would cause spurious echo-PUTs).

**Tech Stack:** Swift 6, SwiftUI, CoreData (lightweight migration), Swift Testing, MockURLProtocol.

**Conventions (apply to every task):**
- Repo practice: commit directly to `develop`. When RED is a compile error, test+impl share ONE commit with the bend noted in the body; otherwise separate RED/GREEN commits.
- Tests run on the PINNED simulator only: `xcrun simctl boot 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB 2>/dev/null; xcrun simctl bootstatus 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB` then `xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB'`. "preflight checks/Busy" is sim noise. SourceKit editor diagnostics are stale-index noise; only xcodebuild output counts.
- macOS check after impl tasks: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build` — zero warnings.
- New files need `make generate` (xcodegen). `.xccurrentversion` updates happen BEFORE `make generate`.
- Mock failures use **422, never 500** (client retries 5xx 3×). Helpers are HTTPURLResponse extensions: `.ok(for: req)` / `.response(for: req, status: 422)` implicit-member spelling.
- `Label` collides with the CoreData entity — SwiftUI labels are spelled `SwiftUI.Label` in views.
- `TDD_IMPLEMENTATION_STATUS.md` (repo root) gains an entry per code commit. Next entry is **#32**, heading format `### 32. Issue #19 Wave 3 Task 1 — ...`. Read the file tail first to match format.
- Baseline: **361 tests / 73 suites** green. Planned progression: T1→364/74, T2→367/74, T3→374/75, T4→379/75, T5→381/75.

---

### Task 1: CoreData v8 — `isWatched` + `isPinned` flags

**Files:**
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 8.xcdatamodel/contents` (copy of v7 + two attributes)
- Modify: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`
- Create: `FenixKanbanTests/Persistence/MigrationModelLoading.swift` (shared helper — consolidation mandated by wave-2 holistic review)
- Modify: `FenixKanbanTests/Persistence/CoreDataMigrationV6Tests.swift`, `CoreDataMigrationV7Tests.swift` (use shared helper)
- Test: `FenixKanbanTests/Persistence/CoreDataMigrationV8Tests.swift`

- [ ] **Step 1: Consolidate the model-loading helper.** READ `CoreDataMigrationV7Tests.swift` and `CoreDataMigrationV6Tests.swift`. Both carry a private `model(named:)` helper (class-stripped versioned-model loading; `named: nil` loads the CURRENT compiled model). Lift it verbatim into a new file `FenixKanbanTests/Persistence/MigrationModelLoading.swift` as an internal free function `migrationTestModel(named:)` (same body, same doc comment noting the class-stripping rationale), and switch both existing suites to call it (delete the private copies). No behavior change.

- [ ] **Step 2: Write the failing tests.** Create `CoreDataMigrationV8Tests.swift`:

```swift
import Testing
import CoreData
@testable import FenixKanban

@Suite("CoreData v7→v8 Migration")
struct CoreDataMigrationV8Tests {

    @Test("v8 Card gains isWatched + isPinned Booleans; assigneesData unchanged")
    func v8ModelShape() throws {
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let card = try #require(v8.entitiesByName["Card"])
        for name in ["isWatched", "isPinned"] {
            let attr = try #require(card.attributesByName[name])
            #expect(attr.attributeType == .booleanAttributeType)
            #expect(!attr.isOptional)
            #expect(attr.defaultValue as? Bool == false)
        }
        #expect(card.attributesByName["assigneesData"] != nil)
    }

    @Test("lightweight mapping v7→v8 is inferable (additive only)")
    func v7ToV8Inferable() throws {
        let v7 = try migrationTestModel(named: "FenixKanban 7")
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v7, destinationModel: v8)
        #expect(!mapping.entityMappings.isEmpty)
    }

    @Test("current model carries Card.isWatched and Card.isPinned (compiled version is v8)")
    func currentModelHasWatchPinFlags() throws {
        let current = try migrationTestModel(named: nil)
        let card = try #require(current.entitiesByName["Card"])
        #expect(card.attributesByName["isWatched"] != nil)
        #expect(card.attributesByName["isPinned"] != nil)
    }
}
```

(The current-model pin test mirrors the wave-2 M1 review fix — it catches a pbxproj `currentVersion` regression. No on-disk survival test: additive-only, same rationale as v7.)

- [ ] **Step 3: Verify RED.** Run `make generate` first (new test files join targets), then tests. Failure reason: "FenixKanban 8" model doesn't exist.

- [ ] **Step 4: Create the v8 model.**

```bash
cd "FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld"
cp -R "FenixKanban 7.xcdatamodel" "FenixKanban 8.xcdatamodel"
```

In `FenixKanban 8.xcdatamodel/contents`, inside `<entity name="Card" ...>`, add after the `isGolden` attribute line (alphabetical, Xcode-canonical):

```xml
<attribute name="isPinned" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
<attribute name="isWatched" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
```

Keep `usedWithCloudKit="YES"` intact. Update `.xccurrentversion`: `<string>FenixKanban 7.xcdatamodel</string>` → `<string>FenixKanban 8.xcdatamodel</string>`. THEN `make generate`.

- [ ] **Step 5: Run tests + both builds, TDD entry #32, commit.** Expected: **364 tests / 74 suites** green; both platforms clean (the V6/V7 refactor must not change their counts).

```bash
git add -A
git commit -m "feat(19): CoreData v8 — isWatched + isPinned flags on Card

Additive-only lightweight migration (two non-optional Booleans with
defaults). Consolidates the migration-test model loader into
MigrationModelLoading.swift (wave-2 holistic review follow-up).
Test+impl in one commit: RED was a missing model version."
```

---

### Task 2: Sync reconciles `isPinned` from `GET /my/pins`

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (steadyStateSync, ~line 124 region + new private method)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (new tests + route `/my/pins` in EVERY existing handler that drives `sync()`)
- Modify: any other test file whose MockURLProtocol handler drives `engine.sync()` (grep — see Step 4)

- [ ] **Step 1: Write the failing tests.** In `FizzySyncEngineTests.swift`, mirror the `pullMapsAssignees` Harness/handler shape. The pins response is the fixture **`FenixKanbanTests/Fixtures/fizzy/pins_doc.json` served verbatim** (wire-shape rule); its first card has `"id": "03f5vaeq985jlvwv3arl4srq2"` — the test's cards payload uses that same id so the pin matches:

```swift
@Test("sync: pins from GET /my/pins land on isPinned (fixture verbatim)")
func syncReconcilesPinsFromMyPins() async throws {
    let h = Harness()
    defer { h.tearDown() }

    let columnsJSON = """
    [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
    """
    // Two cards: the first's id matches pins_doc.json's first pin; the second doesn't.
    let cardsJSON = """
    [{"id":"03f5vaeq985jlvwv3arl4srq2","number":31,"title":"Pinned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/31"},{"id":"fzB2","number":32,"title":"Unpinned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/32"}]
    """
    let pinsData = try loadFixture("pins_doc")   // adapt to this file's actual fixture helper; add one if absent (mirror FizzyClientBoardsTests' loader)
    MockURLProtocol.handler = { req in
        switch (req.httpMethod, req.url?.path) {
        case ("GET", let p?) where p.hasSuffix("/my/pins"):
            return (pinsData, .ok(for: req))
        case ("GET", let p?) where p.hasSuffix("/columns"):
            return (columnsJSON.data(using: .utf8)!, .ok(for: req))
        case ("GET", let p?) where p.hasSuffix("/cards"):
            return (cardsJSON.data(using: .utf8)!, .ok(for: req))
        default:
            Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
            return (Data(), .response(for: req, status: 422))
        }
    }

    _ = try await h.engine.sync()

    let cards = h.cardRepo.fetchAllCards(in: h.board)
    #expect(cards.first { $0.fizzyNumber == 31 }?.isPinned == true)
    #expect(cards.first { $0.fizzyNumber == 32 }?.isPinned == false)
}

@Test("sync: empty pins list clears a previously-pinned card")
func syncClearsUnpinnedCards() async throws {
    // Same harness; cardsJSON with one card (any id); pins route returns "[]".
    // Pre-sync once so the card exists and is paired, set card.isPinned = true
    // directly + save, then sync again and expect isPinned == false.
    // (Mirror the two-round structure of pullClearsOrPreservesAssignees.)
}

@Test("sync: failed pins fetch leaves pin state alone and does not fail the sync")
func pinsFetchFailureLeavesPinStateAlone() async throws {
    // Same harness; pins route EXPLICITLY returns 422 (no Issue.record for it —
    // the failure is the point). Pre-seed a paired card with isPinned = true
    // (sync once with pins serving a matching pin, or set + save directly after
    // a first sync). Second sync with pins → 422: expect sync() does NOT throw,
    // result returned, and isPinned still true.
}
```

Write the second and third tests fully using the structures named in the comments (read `pullClearsOrPreservesAssignees` for the two-round seeding pattern).

- [ ] **Step 2: Verify RED + commit RED.** Failure is an assertion failure (`isPinned` never set — everything referenced exists after Task 1). Note: the two-round tests may ALSO fail at this point because sync() doesn't hit /my/pins yet — `loadFixture`/handler arms going unused is fine; what matters is the final-state assertions fail. Commit just the test changes:

```bash
git add FenixKanbanTests/
git commit -m "test(19): sync reconciles isPinned from GET /my/pins (RED)"
```

- [ ] **Step 3: Implement.** In `FizzySyncEngine.swift`, at the END of `steadyStateSync` (after all push/pull reconciliation, before `mapping.setLastSync(.now)` / the final result return — read the method tail and slot accordingly):

```swift
        // Pin reconciliation (issue #19 wave 3): pins are user-scoped and
        // account-wide; the card wire shape never carries pinned state, so
        // GET /my/pins is the only source of truth. Best-effort — a failed
        // fetch leaves local pin state alone rather than failing the sync.
        await reconcilePins(localBoard: localBoard)
```

New private method:

```swift
    /// Sets `isPinned` on every paired card to match `GET /my/pins`
    /// (remote-authoritative, Captain's ruling #19 wave 3). Deliberately
    /// does NOT bump modifiedAt: pin state is not part of the card-content
    /// LWW contract and must not trigger echo-PUTs.
    private func reconcilePins(localBoard: Board) async {
        guard let pins = try? await client.myPins() else { return }
        let pinnedIDs = Set(pins.map(\.id))
        for column in localBoard.sortedColumns {
            for card in column.sortedCards {
                guard let fizzyID = card.fizzyID else { continue }
                let shouldPin = pinnedIDs.contains(fizzyID)
                if card.isPinned != shouldPin {
                    card.isPinned = shouldPin
                }
            }
        }
        // Persist the same way the rest of the cycle does — check how
        // steadyStateSync saves (if it saves once at the end after this
        // call site, no extra save is needed; otherwise mirror the
        // engine's existing context-save helper).
    }
```

- [ ] **Step 4: Route `/my/pins` in every existing handler that drives `sync()`.** The new fetch hits every steady-state test whose handler's default arm does `Issue.record` + 422. Grep `FenixKanbanTests/` for `MockURLProtocol.handler` in files that call `engine.sync()` or exercise `FizzySyncProvider` sync paths (start with `FizzySyncEngineTests.swift`; check `FizzySyncProviderTests.swift` and siblings). To each affected handler add, as the FIRST GET case:

```swift
case ("GET", let p?) where p.hasSuffix("/my/pins"):
    return (Data("[]".utf8), .ok(for: req))
```

Run the full suite and chase any remaining `unexpected: GET ... /my/pins` failures — zero may remain.

- [ ] **Step 5: Run full suite + macOS build.** Expected: **367 tests / 74 suites** green.

- [ ] **Step 6: TDD entry #33 + GREEN commit.**

```bash
git add -A
git commit -m "feat(19): sync reconciles isPinned from GET /my/pins (GREEN)"
```

---

### Task 3: `toggleWatched` / `togglePinned` in the detail view model

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanban/Core/Repositories/CardRepository.swift`
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests.** New suite cloning `CardDetailViewModelAssignmentPushTests`' harness exactly (paired card `fizzyNumber = 7`, MockURLProtocol client, `.serialized`, `@MainActor`, init-time `MockURLProtocol.reset()`, end-of-test resets):

```swift
@Suite("CardDetailViewModel watch/pin push", .serialized)
@MainActor
struct CardDetailViewModelWatchPinPushTests {
    // init: clone CardDetailViewModelAssignmentPushTests' harness verbatim.

    @Test("toggleWatched POSTs /cards/7/watch and sets the flag")
    func watchPostsToWatchEndpoint() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        await viewModel.toggleWatched()
        #expect(viewModel.isWatched == true)
        #expect(card.isWatched == true)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/7/watch") == true)
        MockURLProtocol.reset()
    }

    @Test("toggleWatched on a watched card DELETEs /cards/7/watch")
    func unwatchDeletes() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.isWatched = true
        try persistence.viewContext.save()
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
        await vm.toggleWatched()
        #expect(vm.isWatched == false)
        #expect(card.isWatched == false)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.path.hasSuffix("/cards/7/watch") == true)
        MockURLProtocol.reset()
    }

    @Test("togglePinned POSTs /cards/7/pin and sets the flag")
    func pinPostsToPinEndpoint() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        await viewModel.togglePinned()
        #expect(viewModel.isPinned == true)
        #expect(card.isPinned == true)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/7/pin") == true)
        MockURLProtocol.reset()
    }

    @Test("togglePinned on a pinned card DELETEs /cards/7/pin")
    func unpinDeletes() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.isPinned = true
        try persistence.viewContext.save()
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
        await vm.togglePinned()
        #expect(vm.isPinned == false)
        #expect(card.isPinned == false)
        let req = MockURLProtocol.requests.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.path.hasSuffix("/cards/7/pin") == true)
        MockURLProtocol.reset()
    }

    @Test("failed watch toggle (422) reverts and surfaces an error")
    func failedWatchToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.toggleWatched()
        #expect(viewModel.isWatched == false)
        #expect(card.isWatched == false)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("failed pin toggle (422) reverts and surfaces an error")
    func failedPinToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        await viewModel.togglePinned()
        #expect(viewModel.isPinned == false)
        #expect(card.isPinned == false)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }
}
```

And in the ORIGINAL unpaired/no-client suite (match its conventions, like `unpairedToggleAssignmentNoOp`):

```swift
@Test("unpaired card: watch/pin toggles are no-ops with zero network")
func unpairedWatchPinNoOp() async throws {
    MockURLProtocol.reset()
    defer { MockURLProtocol.reset() }
    await viewModel.toggleWatched()
    await viewModel.togglePinned()
    #expect(viewModel.isWatched == false)
    #expect(viewModel.isPinned == false)
    #expect(MockURLProtocol.requests.isEmpty)
}
```

- [ ] **Step 2: Verify RED.** Compile error (`toggleWatched`/`isWatched` etc. don't exist on the VM) — one commit, bend noted.

- [ ] **Step 3: Implement.**

`CardRepository.swift` — add near `updateAssignees`:

```swift
    /// Watch/pin flags deliberately do NOT bump modifiedAt: they're not part
    /// of the card-content LWW contract (never pushed in the PUT payload) and
    /// bumping would trigger spurious echo-PUTs on the next sync (#19 wave 3).
    func setWatched(_ watched: Bool, for card: Card) {
        card.isWatched = watched
        save()
    }

    func setPinned(_ pinned: Bool, for card: Card) {
        card.isPinned = pinned
        save()
    }
```

`CardDetailViewModel.swift` — add published state:

```swift
    @Published var isWatched: Bool
    @Published var isPinned: Bool
```

in `init` (after `self.assignees = card.assignees`):

```swift
        self.isWatched = card.isWatched
        self.isPinned = card.isPinned
```

Refactor the gate (keep `canEditAssignments` as a delegating alias — Task 5's UI and existing tests use both):

```swift
    /// Fizzy-only affordances (assignments, watch, pin) share this gate:
    /// paired card + live client (issue #19).
    var isFizzyPaired: Bool {
        card.fizzyNumber > 0 && fizzyClient != nil
    }

    var canEditAssignments: Bool { isFizzyPaired }
```

Add the toggles (near `toggleAssignment`):

```swift
    /// Watch state is local write-only: Fizzy accepts watch/unwatch but never
    /// reports current state (no wire field, no watchers endpoint) — Captain's
    /// ruling, #19 wave 3. Optimistic flip + state-recheck revert; can drift
    /// if toggled from another client (documented MVP limitation).
    func toggleWatched() async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasWatched = isWatched
        isWatched = !wasWatched
        cardRepository.setWatched(isWatched, for: card)
        do {
            if wasWatched {
                try await client.unwatchCard(number: Int(card.fizzyNumber))
            } else {
                try await client.watchCard(number: Int(card.fizzyNumber))
            }
        } catch {
            // Revert only if no later toggle changed the state in flight.
            if isWatched != wasWatched {
                isWatched = wasWatched
                cardRepository.setWatched(isWatched, for: card)
            }
            errorMessage = "Couldn't update watch state on Fizzy."
        }
    }

    /// Pin state is remote-authoritative via GET /my/pins on sync; the toggle
    /// is optimistic with state-recheck revert (issue #19 wave 3).
    func togglePinned() async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasPinned = isPinned
        isPinned = !wasPinned
        cardRepository.setPinned(isPinned, for: card)
        do {
            if wasPinned {
                try await client.unpinCard(number: Int(card.fizzyNumber))
            } else {
                try await client.pinCard(number: Int(card.fizzyNumber))
            }
        } catch {
            if isPinned != wasPinned {
                isPinned = wasPinned
                cardRepository.setPinned(isPinned, for: card)
            }
            errorMessage = "Couldn't update pin on Fizzy."
        }
    }
```

(Verify `watchCard`/`unwatchCard`/`pinCard`/`unpinCard` signatures in `FizzyClient+CardActions.swift:63-101` and match.)

- [ ] **Step 4: Run full suite.** Expected: **374 tests / 75 suites** green; macOS clean.

- [ ] **Step 5: TDD entry #34 + commit.**

```bash
git add -A
git commit -m "feat(19): watch + pin toggles push to Fizzy, optimistic w/ revert

Test+impl in one commit: RED state was a compile error (new members)."
```

---

### Task 4: Golden pushes to Fizzy (all entry points)

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift` (toggleGolden ~line 140)
- Modify: `FenixKanban/Features/Card/CardDetailView.swift` (toolbar call sites, both platforms, ~lines 139-162)
- Modify: `FenixKanban/Features/Board/BoardViewModel.swift` (toggleGolden(for:) ~line 112; init gains optional client)
- Modify: whichever view constructs BoardViewModel (find it — BoardView or its container; wire the client via `PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider` → `makeClient()`, same as CardDetailView's init does)
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`, `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift`

**Why:** `applyRemote` sets `card.isGolden = remote.golden` on every pull (remote-authoritative), but no push path carries golden — so today every golden flip on a paired card silently reverts on a later pull. The goldness endpoints (`markCardGolden`/`unmarkCardGolden`, `FizzyClient+CardActions.swift:75-83`) close the loop.

- [ ] **Step 1: Write the failing tests.**

In `CardDetailViewModelWatchPinPushTests` (paired suite from Task 3):

```swift
@Test("toggleGolden on a paired card POSTs /cards/7/goldness")
func goldenTogglePostsGoldness() async throws {
    MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
    await viewModel.toggleGolden()
    #expect(card.isGolden == true)
    let req = MockURLProtocol.requests.first
    #expect(req?.httpMethod == "POST")
    #expect(req?.url?.path.hasSuffix("/cards/7/goldness") == true)
    MockURLProtocol.reset()
}

@Test("toggleGolden on a golden paired card DELETEs /cards/7/goldness")
func goldenToggleUnmarksDeletes() async throws {
    MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
    card.isGolden = true
    try persistence.viewContext.save()
    await viewModel.toggleGolden()
    #expect(card.isGolden == false)
    let req = MockURLProtocol.requests.first
    #expect(req?.httpMethod == "DELETE")
    #expect(req?.url?.path.hasSuffix("/cards/7/goldness") == true)
    MockURLProtocol.reset()
}

@Test("failed golden push (422) reverts and surfaces an error")
func failedGoldenToggleReverts() async throws {
    MockURLProtocol.handler = { request in
        (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
    }
    await viewModel.toggleGolden()
    #expect(card.isGolden == false)
    #expect(viewModel.errorMessage != nil)
    MockURLProtocol.reset()
}
```

In `BoardViewModelGoldenTests.swift` — READ the file first; its existing harness has no client. Add two tests that construct their own MockURLProtocol-backed client (clone the client construction from `CardDetailViewModelAssignmentPushTests`) and a BoardViewModel with it; the board push is fire-and-forget, so await it with a bounded yield loop:

```swift
@Test("board golden toggle on a paired card pushes goldness")
func boardTogglePushesGoldness() async throws {
    // own harness: persistence, board/column, paired card (fizzyID="fzG",
    // fizzyNumber=9), MockURLProtocol client, BoardViewModel(..., fizzyClient: client)
    MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
    viewModel.toggleGolden(for: card)
    #expect(card.isGolden == true)
    var spins = 0
    while MockURLProtocol.requests.isEmpty && spins < 1000 { await Task.yield(); spins += 1 }
    let req = MockURLProtocol.requests.first
    #expect(req?.httpMethod == "POST")
    #expect(req?.url?.path.hasSuffix("/cards/9/goldness") == true)
    MockURLProtocol.reset()
}

@Test("board golden toggle on an unpaired card stays local, zero network")
func boardToggleUnpairedNoNetwork() async throws {
    MockURLProtocol.reset()
    defer { MockURLProtocol.reset() }
    // existing-harness unpaired card + a BoardViewModel WITH a client
    viewModel.toggleGolden(for: unpairedCard)
    #expect(unpairedCard.isGolden == true)
    for _ in 0..<50 { await Task.yield() }
    #expect(MockURLProtocol.requests.isEmpty)
}
```

(Adapt names/harness details to the file's actual conventions. If `BoardViewModelGoldenTests` isn't `.serialized`, these MockURLProtocol tests need a `.serialized` sub-suite or suite-level change — match how other MockURLProtocol suites handle it.)

Also UPDATE `toggleGoldenFlips` in the unpaired detail suite: `viewModel.toggleGolden()` → `await viewModel.toggleGolden()` (it becomes async; unpaired → no push, assertions unchanged).

- [ ] **Step 2: Verify RED.** Compile error in the board tests (`fizzyClient:` init param doesn't exist) and the detail tests fail to find network calls — one commit, bend noted.

- [ ] **Step 3: Implement.**

`CardDetailViewModel.swift` — replace `toggleGolden`:

```swift
    /// Golden is local-first (works unpaired); paired cards also push to
    /// Fizzy's goldness endpoint so the next pull doesn't revert the flip —
    /// applyRemote is remote-authoritative on `golden` (#19 wave 3 fixes
    /// the silent-revert latent bug). State-recheck revert on failure.
    func toggleGolden() async {
        let wasGolden = card.isGolden
        applyGoldenLocally(!wasGolden)

        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        do {
            if wasGolden {
                try await client.unmarkCardGolden(number: Int(card.fizzyNumber))
            } else {
                try await client.markCardGolden(number: Int(card.fizzyNumber))
            }
        } catch {
            if card.isGolden != wasGolden {
                applyGoldenLocally(wasGolden)
            }
            errorMessage = "Couldn't update golden ticket on Fizzy."
        }
    }

    private func applyGoldenLocally(_ golden: Bool) {
        card.isGolden = golden
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? card.managedObjectContext?.save()
        objectWillChange.send()
    }
```

(Golden KEEPS the modifiedAt bump — unlike watch/pin, golden is part of the pulled card content, and the bump blocks the LWW pull branch until the push cycle completes, protecting against a stale-pull race.)

`CardDetailView.swift` — both toolbar buttons: `viewModel.toggleGolden()` → `Task { await viewModel.toggleGolden() }`.

`BoardViewModel.swift` — init gains `fizzyClient: FizzyClient? = nil` (stored `private let`; default nil keeps every existing construction site and test compiling). `toggleGolden(for:)` gains a trailing `pushGolden(for: card)` call:

```swift
    /// Fire-and-forget push for board-surface golden toggles (context menu,
    /// swipe). The board has no alert affordance, so a failed push reverts
    /// silently — without the push, the next pull reverted it anyway.
    private func pushGolden(for card: Card) {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let isGolden = card.isGolden
        Task { @MainActor in
            do {
                if isGolden {
                    try await client.markCardGolden(number: Int(card.fizzyNumber))
                } else {
                    try await client.unmarkCardGolden(number: Int(card.fizzyNumber))
                }
            } catch {
                // State-recheck: only revert if nothing changed it since.
                if card.isGolden == isGolden {
                    card.isGolden = !isGolden
                    card.modifiedAt = Date()
                    try? self.context.save()
                    self.refreshColumns()
                }
            }
        }
    }
```

(Match BoardViewModel's actual actor isolation — if the class is already `@MainActor`, drop the explicit annotation on the Task. `toggleGolden(cardID:)` funnels through `toggleGolden(for:)`, so it inherits the push.)

Wire the client where BoardViewModel is constructed: find the construction site (grep `BoardViewModel(`), resolve `(PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider)?.makeClient()` exactly as `CardDetailView.init` does, and pass it.

- [ ] **Step 4: Run full suite.** Expected: **379 tests / 75 suites** green; macOS clean.

- [ ] **Step 5: TDD entry #35 + commit.**

```bash
git add -A
git commit -m "feat(19): golden toggles push goldness to Fizzy from all surfaces

Fixes the latent silent-revert: applyRemote is remote-authoritative on
golden but nothing pushed it. Test+impl in one commit: RED was a
compile error (BoardViewModel init signature)."
```

---

### Task 5: Watch/Pin UI — detail toggles + card-face indicators

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`
- Modify: `FenixKanban/Features/Card/CardView.swift`
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Gating tests.** In the watch/pin push suite: `#expect(viewModel.isFizzyPaired == true)` as `pairedCardIsFizzyPaired`; in the unpaired suite: `#expect(viewModel.isFizzyPaired == false)` as `unpairedCardIsNotFizzyPaired`. (`isFizzyPaired` shipped in Task 3, so these compile and PASS immediately — note in the commit body in lieu of RED; they lock the gate.)

- [ ] **Step 2: Detail toggles.** In `CardDetailView.swift`, after the Assignees block (the one gated `viewModel.canEditAssignments`), add:

```swift
                // Watch / Pin (fizzy-paired cards only — issue #19 wave 3).
                // Watch is local write-only state (server never reports it);
                // pin reconciles from GET /my/pins on sync.
                if viewModel.isFizzyPaired {
                    Toggle(isOn: Binding(
                        get: { viewModel.isWatched },
                        set: { _ in Task { await viewModel.toggleWatched() } }
                    )) {
                        SwiftUI.Label("Watch", systemImage: "eye")
                    }
                    .accessibilityHint("Subscribes to activity on this card on Fizzy.")

                    Toggle(isOn: Binding(
                        get: { viewModel.isPinned },
                        set: { _ in Task { await viewModel.togglePinned() } }
                    )) {
                        SwiftUI.Label("Pin", systemImage: "pin")
                    }
                    .accessibilityHint("Pins this card to your Fizzy pins.")
                }
```

(`SwiftUI.Label` — the bare name collides with the CoreData `Label` entity. Toggle failures surface via the existing "Sync Error" alert. No `.background`; nothing attaches to a `Section`.)

- [ ] **Step 3: Card-face indicators.** In `CardView.swift`, the title HStack currently reads:

```swift
            HStack {
                Text(card.title ?? "Untitled")
                    .font(.crossPlatformSubheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .strikethrough(card.isCompleted)
                    .foregroundStyle(card.isCompleted ? .secondary : .primary)

                Spacer()
            }
```

Add the indicators inline after the `Spacer()` (inline, NOT an overlay — the top-trailing corner can collide with two-line titles; the golden ticket already owns top-leading):

```swift
                if card.isPinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                if card.isWatched {
                    Image(systemName: "eye.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Watching")
                }
```

(Secondary tint = content tint, not chrome — Liquid Glass safe; golden keeps its existing gold accent per the Captain's ruling.)

- [ ] **Step 4: Run full suite + macOS build.** Expected: **381 tests / 75 suites** green; macOS BUILD SUCCEEDED, zero warnings. No new files → no `make generate`.

- [ ] **Step 5: TDD entry #36 + commit.**

```bash
git add -A
git commit -m "feat(19): watch/pin toggles in card detail + card-face indicators

Gating tests pass immediately (isFizzyPaired shipped in Task 3) —
noted in lieu of a RED phase; they lock the exposure gate."
```

---

### Task 6: Finalize — full verification, status doc, report

- [ ] **Step 1: Full verification pass** (pinned-sim test run + iOS and macOS builds). Expected: **381 tests / 75 suites** green, zero warnings.

- [ ] **Step 2: Append the wave close-out summary** to `TDD_IMPLEMENTATION_STATUS.md` (entry **#37**, mirroring the #31 close-out format): what shipped per task, commits, verification counts (361/73 → 381/75), review-fix notes, and gray areas:
  - Watch state is write-only/local-best-guess — drifts if toggled from another client; no server read API exists.
  - Pin reconcile can race a just-toggled pin if the sync's pins fetch predates the toggle's POST — the next cycle self-heals.
  - `GET /my/pins` is unpaginated, capped at 100 pins — irrelevant at MVP scale.
  - Board-surface golden push failures revert silently (board has no alert affordance; detail surface shows the Sync Error alert).
  - Watch/pin flags deliberately skip the modifiedAt bump (no echo-PUT); golden keeps it (LWW pull-block protection for pulled content).
  - CloudKit: v8's two Boolean attrs join the #20 schema-deploy checklist (schema-additive, ordinary-save export path).

- [ ] **Step 3: Commit** — `git commit -m "docs: log #19 wave 3 (watch/pin/golden) in TDD status"`

- [ ] **Step 4: Report back to the Captain** — what shipped, test delta, deviations, and a proposed #19 comment + #20 checklist addition (GitHub posting needs fresh explicit approval).

---

## Known risks & decisions encoded above

1. **Watch = local write-only flag** (Captain's ruling) — Fizzy has no read API for watch state; the flag persists optimistic local truth and can drift. Documented MVP limitation, not a bug.
2. **Pin = sync-reconciled from `GET /my/pins`** (Captain's ruling) — remote-authoritative; reconciliation is failure-tolerant (a failed pins fetch never fails the sync or clears flags) and skips the modifiedAt bump.
3. **The `/my/pins` fetch touches every steady-sync test** — their handlers' default arms `Issue.record` on unexpected requests. Task 2 Step 4 routes the path (`"[]"`) in every affected handler; this is mechanical but mandatory.
4. **Golden keeps its modifiedAt bump; watch/pin don't** — golden is pulled card content (the bump blocks the LWW pull branch until push, preventing stale-pull reverts); watch/pin are never pulled via applyRemote, so a bump would only cause echo-PUTs.
5. **BoardViewModel's push is fire-and-forget** — board surfaces have no alert affordance; failed pushes revert silently via state-recheck. The `fizzyClient: FizzyClient? = nil` default keeps all existing constructions/tests compiling.
6. **`toggleGolden` becomes async** — call sites updated (detail toolbar `Task { await ... }`); `toggleGoldenFlips` test gains `await`. Unpaired behavior is byte-identical (guard sits after the local flip).
