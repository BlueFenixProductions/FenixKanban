# Issue #20 — Snapshot-Staleness Family + Deleted-Card Guard Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `CardDetailViewModel` init-time snapshot staleness (labels / assignees / watched / pinned go stale when a sync lands under an open detail sheet — the labels variant clobbers remote-added labels on `save()`), and guard the five fizzy revert paths against a card soft-deleted mid-flight.

**Architecture:** One mechanism fixes all four staleness variants: observe `.NSManagedObjectContextObjectsDidChange` on the card's context (the established `BoardListViewModel.observeChanges()` pattern — fires for both local saves and CloudKit/background-context merges) and re-read the four sync-authoritative fields when the card is among updated/refreshed objects. Text-edit fields (`title`, `cardDescription`, `dueDate`, `isCompleted`) are deliberately NOT refreshed — that would clobber in-progress typing (documented LWW). The guard family copies the existing `BoardViewModel` precedent (`!card.isDeleted, card.managedObjectContext != nil`, BoardViewModel.swift:140) into the five catch-revert paths.

**Tech Stack:** Swift 5.9, SwiftUI + Core Data (`NSPersistentCloudKitContainer` in prod, in-memory `NSPersistentContainer` in tests), Swift Testing (`@Test`/`@Suite`/`#expect`), MockURLProtocol for fizzy HTTP.

---

## Scope ruling: the original #20 backfill is VOID

Issue #20's headline item (flag-gated backfill of migrated card→label links) was filed
2026-06-11T00:01:29Z (= 2026-06-10 19:01 CDT) — **38 minutes before** commit `f07b3d7`
(2026-06-10 19:39 CDT, "fix: drop label→labels renaming identifier — CloudKit forbids
renames"). Under the Captain's ruling, v5-era card→label links are **dropped by the
migration by design** (documented in `CoreDataMigrationV6Tests.swift` header); Fizzy
re-pulls tags on the next sync. There are no migrated links to backfill, hence no
re-export gap. What survives from the #20 thread:

1. **Snapshot-staleness family** (this plan, Task 1) — labels (the data-loss one),
   assignees, watched, pinned.
2. **Deleted-card guard family** (this plan, Task 2) — five revert paths.
3. **CloudKit schema deploy checklist** (captain-gated, NOT code): run
   `initializeCloudKitSchema()` in development against the current model so the v6
   `Card.labels` many-to-many (CDMR), v7 `assigneesData`, and v8 `isWatched`/`isPinned`
   exist in the CloudKit schema, then deploy to production in the Dashboard before any
   CloudKit-enabled release. Needs iCloud credentials — flagged back on the issue.

---

### Task 1: Sync-refresh of snapshot fields

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift` (add observer + refresh)
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` (new suite at end of file + one test in `CardDetailViewModelAssignmentPushTests`)

- [ ] **Step 1: Write the failing tests**

Append a new suite at the end of `CardDetailViewModelTests.swift`:

```swift
@Suite("CardDetail ViewModel — sync refresh (#20 snapshot family)", .serialized)
@MainActor
struct CardDetailViewModelSyncRefreshTests {
    let persistence: PersistenceController
    let card: Card
    let viewModel: CardDetailViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Open Card")
        try! persistence.viewContext.save()
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext)
    }

    @Test("a label added underneath the open sheet refreshes selectedLabels")
    func remoteLabelAdditionRefreshesSelection() {
        let remote = LabelRepository(context: persistence.viewContext)
            .createLabel(name: "remote", colorHex: "#00FF00")
        card.addToLabels(remote)
        persistence.viewContext.processPendingChanges()

        #expect(viewModel.selectedLabels == [remote])
    }

    @Test("a label added underneath the open sheet survives save() — the #20 clobber")
    func remoteLabelAdditionSurvivesSave() {
        let remote = LabelRepository(context: persistence.viewContext)
            .createLabel(name: "remote", colorHex: "#00FF00")
        card.addToLabels(remote)
        persistence.viewContext.processPendingChanges()

        viewModel.title = "Edited while open"
        viewModel.save()

        #expect((card.labels as? Set<Label>) == [remote])
    }

    @Test("watch/pin flags written underneath the open sheet refresh the toggles")
    func remoteWatchPinRefresh() {
        card.isWatched = true
        card.isPinned = true
        persistence.viewContext.processPendingChanges()

        #expect(viewModel.isWatched == true)
        #expect(viewModel.isPinned == true)
    }

    @Test("an assignee blob written underneath the open sheet refreshes assignees")
    func remoteAssigneeRefresh() {
        card.assignees = [CardAssignee(id: "bg", name: "Background Bee")]
        persistence.viewContext.processPendingChanges()

        #expect(viewModel.assignees.map(\.id) == ["bg"])
    }
}
```

And in the existing `CardDetailViewModelAssignmentPushTests` suite (after
`toggleRemovesAssigned`), the wave-2 variant lock:

```swift
    @Test("toggle preserves an assignee pulled in the background (#20 snapshot family)")
    func togglePreservesBackgroundPulledAssignee() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        // A sync pull lands while the sheet is open: the blob gains "bg".
        card.assignees = [CardAssignee(id: "bg", name: "Background Bee")]
        persistence.viewContext.processPendingChanges()
        let user = FizzyUser(id: "u2", name: "Toggled Tom", role: "member", active: true,
                             emailAddress: "t@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(Set(card.assignees.map(\.id)) == ["bg", "u2"])
        MockURLProtocol.reset()
    }
```

- [ ] **Step 2: Run the new tests, verify they fail for the right reason**

Run (pinned sim — two-sim flake rule, UDID `1CCA4B1C…`; boot + bootstatus first):
`xcodebuild test -scheme FenixKanban -destination 'id=<pinned-UDID>' -only-testing:FenixKanbanTests/CardDetailViewModelSyncRefreshTests -only-testing:FenixKanbanTests/CardDetailViewModelAssignmentPushTests`
Expected: the 4 new suite tests FAIL (snapshots never refresh), `togglePreservesBackgroundPulledAssignee` FAILS (`["u2"]` ≠ `["bg","u2"]` — the stale array clobbers "bg"). All pre-existing tests PASS.

- [ ] **Step 3: Commit the failing tests**

```bash
git add FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift
git commit -m "test(20): RED — snapshot fields go stale under an open detail sheet"
```

- [ ] **Step 4: Implement the observer + refresh**

In `CardDetailViewModel.swift` — add a stored token next to the other private lets:

```swift
    private var observerToken: (any NSObjectProtocol)?
```

At the end of `init`, after the `stepsViewModel` assignment:

```swift
        observeCardChanges(context: context)
```

Add (plus a `deinit` mirroring `BoardViewModel`'s):

```swift
    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The four sync-authoritative snapshot fields (labels, assignees, watch,
    /// pin) go stale when a sync or CloudKit merge lands while the detail
    /// sheet is open — the next save() would write the stale labels set back
    /// over a remote addition (#20). Re-read them whenever this card changes
    /// underneath us. Text-edit fields (title, description, dueDate,
    /// isCompleted) stay untouched: refreshing those would clobber
    /// in-progress typing (documented LWW).
    private func observeCardChanges(context: NSManagedObjectContext) {
        observerToken = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.refreshSnapshotFields(from: notification)
            }
        }
    }

    private func refreshSnapshotFields(from notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]
            .compactMap { userInfo[$0] as? Set<NSManagedObject> }
            .reduce(Set<NSManagedObject>()) { $0.union($1) }
        guard changed.contains(card), !card.isDeleted, card.managedObjectContext != nil else { return }
        selectedLabels = card.labels as? Set<Label> ?? []
        assignees = card.assignees
        isWatched = card.isWatched
        isPinned = card.isPinned
    }
```

- [ ] **Step 5: Run the tests, verify GREEN; run both CardDetail suites**

Same command as Step 2. Expected: all PASS. Then the full `FenixKanbanTests` bundle to catch regressions (the observer also fires on the VM's own saves — must be a no-op).

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailViewModel.swift
git commit -m "fix(20): refresh sync-authoritative snapshot fields under an open detail sheet"
```

### Task 2: Deleted-card guard family (five revert paths)

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift` (guard in 5 catch blocks)
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` (new suite)

- [ ] **Step 1: Write the failing tests**

Append a new suite. The mid-flight deletion is simulated from the mock handler: while
the toggle is suspended awaiting the HTTP response, the handler hops to the main queue
(free — the test is suspended, not blocking) and deletes + saves the card, then answers
404. Every revert path must notice the dead card and stand down.

```swift
@Suite("CardDetail ViewModel — deleted-card revert guards (#20 guard family)", .serialized)
@MainActor
struct CardDetailViewModelDeletedCardGuardTests {
    let persistence: PersistenceController
    let card: Card
    let label: Label
    let viewModel: CardDetailViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Doomed Card")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        label = LabelRepository(context: persistence.viewContext).createLabel(name: "bug", colorHex: "#FF0000")
        try! persistence.viewContext.save()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)

        // Sync soft-deletes the card while the push is in flight, then the
        // push fails: the catch revert must not touch the dead card.
        let context = persistence.viewContext
        let doomed = card
        MockURLProtocol.handler = { request in
            DispatchQueue.main.sync {
                if !doomed.isDeleted, doomed.managedObjectContext != nil {
                    context.delete(doomed)
                    try? context.save()
                }
            }
            return (Data("{\"error\":\"gone\"}".utf8), .response(for: request, status: 404))
        }
    }

    @Test("label revert stands down on a deleted card")
    func labelRevertGuarded() async {
        await viewModel.toggleLabel(label)
        #expect(viewModel.errorMessage == nil)
        MockURLProtocol.reset()
    }

    @Test("assignment revert stands down on a deleted card")
    func assignmentRevertGuarded() async {
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)
        await viewModel.toggleAssignment(user)
        #expect(viewModel.errorMessage == nil)
        MockURLProtocol.reset()
    }

    @Test("watch revert stands down on a deleted card")
    func watchRevertGuarded() async {
        await viewModel.toggleWatched()
        #expect(viewModel.errorMessage == nil)
        MockURLProtocol.reset()
    }

    @Test("pin revert stands down on a deleted card")
    func pinRevertGuarded() async {
        await viewModel.togglePinned()
        #expect(viewModel.errorMessage == nil)
        MockURLProtocol.reset()
    }

    @Test("golden revert stands down on a deleted card")
    func goldenRevertGuarded() async {
        await viewModel.toggleGolden()
        #expect(viewModel.errorMessage == nil)
        MockURLProtocol.reset()
    }
}
```

- [ ] **Step 2: Run, verify RED for the right reason**

Expected: each test fails — either `errorMessage` is set by the unguarded catch, or
the revert write fires a fault on the zombie card and the run records the issue as a
crash/«unknown» (precedent: status log #43 — red regardless, and the crash IS the bug
the guards prevent). Pre-existing suites still PASS.

- [ ] **Step 3: Commit the failing tests**

```bash
git add FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift
git commit -m "test(20): RED — revert paths touch a card sync-deleted mid-flight"
```

- [ ] **Step 4: Guard the five catch blocks**

In each of `toggleLabel` / `toggleAssignment` / `toggleWatched` / `togglePinned` /
`toggleGolden`, insert as the FIRST line of the `catch` block (before any card read —
`toggleGolden`'s catch reads `card.isGolden`, which faults on a zombie):

```swift
            // A sync can soft-delete the card while the push is in flight
            // (#20 guard family, BoardViewModel:140 precedent): reverting a
            // dead card would fire a fault. Stand down — the failure is moot.
            guard !card.isDeleted, card.managedObjectContext != nil else { return }
```

- [ ] **Step 5: Run, verify GREEN; full bundle**

All 5 new tests PASS, full `FenixKanbanTests` bundle PASSES.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailViewModel.swift
git commit -m "fix(20): revert paths stand down on a card sync-deleted mid-flight"
```

### Task 3: Verification + bookkeeping

- [ ] **Step 1: Full verification per definition-of-done**

1. Boot pinned sim (`xcrun simctl boot 1CCA4B1C…` + `bootstatus`), full iOS test run: expect **all suites green, zero warnings**.
2. macOS build: `xcodebuild build -scheme FenixKanban -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` — expect `BUILD SUCCEEDED`, zero warnings.

- [ ] **Step 2: Append TDD_IMPLEMENTATION_STATUS.md entry (#45)** — backfill-void ruling + both families, final counts.

- [ ] **Step 3: Commit docs, merge/push develop**

```bash
git add TDD_IMPLEMENTATION_STATUS.md docs/superpowers/plans/2026-06-11-20-snapshot-staleness-and-guards.md
git commit -m "docs(20): status log #45 — snapshot staleness + deleted-card guards"
```

- [ ] **Step 4: Comment on issue #20**: backfill premise void (chronology evidence `f07b3d7`), what shipped (both families + test locks), what remains captain-gated (CloudKit schema init + Dashboard deploy checklist: v6 `labels` CDMR, v7 `assigneesData`, v8 `isWatched`/`isPinned`).
