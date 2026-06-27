# Decouple UI/runtime reads from CoreData pairing hints (#22) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every UI/runtime reader resolve a card's Fizzy pairing store-first (CoreData hint attribute as fallback), so `FizzyCardPairingStore` is the published source of truth without touching the hint-write/seed/heal machinery or the CoreData attributes.

**Architecture:** One `Card` extension (`resolvedFizzyNumber` / `resolvedFizzyID`) centralizes the store-first-with-attribute-fallback resolution (mirroring the existing `CardRepository:111` pattern). Each view-model/view reader switches its `card.fizzyNumber` / `card.fizzyID` reads to the helper, gaining an injected `pairingStore` where it doesn't already have one. The hint channel (writes, `seedPairingStoreFromHints`, `healHints`) and the CoreData attributes stay intact — gated to a future v10.

**Tech Stack:** Swift, SwiftUI, CoreData, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), xcodegen, xcodebuild.

## Global Constraints

- **Tests use Swift Testing**, not XCTest: `@Suite`, `@Test`, `#expect`, `#require`. Match the existing suites' style.
- **Read strategy is store-first with attribute fallback**, verbatim shape: `id.flatMap { store.pairing(for: $0)?.fizzyNumber } ?? fizzyNumber`. Never pure store-only (a cold-device pre-seed window would flip a paired card to unpaired).
- **Pairing-store injection convention:** view-model inits gain `pairingStore: FizzyCardPairingStore = .shared` (defaulted). The `Card+Pairing` helper's `store` parameter is **non-defaulted** (forces callers to pass their injected store).
- **Do NOT touch (v10-gated):** `FizzySyncEngine.seedPairingStoreFromHints` / `healHints`; hint *writes* and tombstone fallbacks in `CardRepository` / `BoardRepository`; the CoreData attributes `fizzyID` / `fizzyNumber` / `fizzyUpdatedAt` / `fizzyEtag`. No `.xcdatamodel` version bump. `CardView.swift:43` already reads the store directly — leave it.
- **Test destination (anti-flake):** always run targeted suites with the pinned simulator UDID, never `name=iPhone 17` (two-iPhone-17 ambiguity flake, per `Makefile:97-98`):
  `-destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB'`
- **New files** must be picked up by xcodegen: run `make generate` after creating any `.swift` file, before building/testing.
- **Branch:** `claude/22-decouple-ui-pairing-reads` (already exists off `origin/main`; the design spec is already committed there).
- **Commits:** subject style `type(#22): summary`. Stage explicit paths (never `git add -A` / `git add .`). Do **not** add a `Co-Authored-By` trailer.
- **Per-task gate before commit:** the task's own test suite passes on the pinned simulator. **Final gate (Task 7):** `make test` full suite + `make symbols` + `xcodebuild build -destination 'generic/platform=macOS'` all green.

---

### Task 1: `Card+Pairing` resolution helper

**Files:**
- Create: `FenixKanban/Core/Persistence/Card+Pairing.swift`
- Test: `FenixKanbanTests/Core/Persistence/CardPairingTests.swift`

**Interfaces:**
- Produces: `Card.resolvedFizzyNumber(_ store: FizzyCardPairingStore) -> Int64` and `Card.resolvedFizzyID(_ store: FizzyCardPairingStore) -> String?`. Both consumed by Tasks 3–6.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Core/Persistence/CardPairingTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card pairing resolution", .serialized)
@MainActor
struct CardPairingTests {
    let persistence: PersistenceController
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = CardRepository(context: persistence.viewContext).createCard(in: column, title: "Card")
    }

    private func makeStore() -> FizzyCardPairingStore {
        FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
    }

    @Test("falls back to the CoreData attribute when the store has no entry")
    func fallbackToAttribute() {
        let store = makeStore()
        card.fizzyNumber = 42
        card.fizzyID = "fz-42"
        #expect(card.resolvedFizzyNumber(store) == 42)
        #expect(card.resolvedFizzyID(store) == "fz-42")
    }

    @Test("store value wins over the CoreData attribute")
    func storeWins() {
        let store = makeStore()
        card.fizzyNumber = 42
        card.fizzyID = "fz-42"
        store.setPairing(
            FizzyCardPairing(fizzyID: "fz-99", fizzyNumber: 99, fizzyUpdatedAt: .now),
            for: card.id!
        )
        #expect(card.resolvedFizzyNumber(store) == 99)
        #expect(card.resolvedFizzyID(store) == "fz-99")
    }

    @Test("unpaired in both store and attribute yields 0 / nil")
    func unpairedDefaults() {
        let store = makeStore()
        #expect(card.resolvedFizzyNumber(store) == 0)
        #expect(card.resolvedFizzyID(store) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardPairingTests 2>&1 | tail -30
```
Expected: FAIL — `value of type 'Card' has no member 'resolvedFizzyNumber'` (the suite won't compile until Step 3).

- [ ] **Step 3: Create the helper**

Create `FenixKanban/Core/Persistence/Card+Pairing.swift`:

```swift
import CoreData

extension Card {
    /// Fizzy card number, resolved store-first with CoreData-hint fallback (#22).
    /// The store wins when a pairing exists; the `fizzyNumber` attribute answers
    /// only during the pre-seed window on a cold device. Returns 0 when the card
    /// is unpaired in both — preserving the `> 0` paired gate at call sites.
    func resolvedFizzyNumber(_ store: FizzyCardPairingStore) -> Int64 {
        id.flatMap { store.pairing(for: $0)?.fizzyNumber } ?? fizzyNumber
    }

    /// Fizzy card id, resolved store-first with CoreData-hint fallback (#22).
    func resolvedFizzyID(_ store: FizzyCardPairingStore) -> String? {
        id.flatMap { store.pairing(for: $0)?.fizzyID } ?? fizzyID
    }
}
```

- [ ] **Step 4: Regenerate the project, then run the test to verify it passes**

Run:
```bash
make generate
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardPairingTests 2>&1 | tail -30
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Persistence/Card+Pairing.swift \
        FenixKanbanTests/Core/Persistence/CardPairingTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(#22): add Card store-first pairing resolution helper"
```

---

### Task 2: `CardStepsViewModel` — inject the resolved card number

The designated init currently derives `Int(card.fizzyNumber)` itself (line 37). Move that decision out: take a resolved `cardNumber: Int` so the *caller* (CardDetailViewModel, Task 3) supplies the store-first value.

**Files:**
- Modify: `FenixKanban/Features/Card/CardStepsViewModel.swift:35-63`
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift:56` (compile-fix only — full conversion is Task 3)
- Test: `FenixKanbanTests/Features/Card/CardStepsViewModelTests.swift:61-63`

**Interfaces:**
- Produces: `CardStepsViewModel(card: Card, cardNumber: Int, client: FizzyClient, repository: StepRepository)` (designated init gains `cardNumber:`).
- Consumes: nothing new.

- [ ] **Step 1: Update the test call site to the new signature (fails to compile first)**

In `FenixKanbanTests/Features/Card/CardStepsViewModelTests.swift`, change `makeVM()` (lines 61-63):

```swift
    private func makeVM() -> CardStepsViewModel {
        CardStepsViewModel(card: card, cardNumber: Int(card.fizzyNumber), client: makeClient(), repository: makeRepo())
    }
```

(Passing `Int(card.fizzyNumber)` preserves the exact number the suite used before — behavior-preserving.)

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardStepsViewModelTests 2>&1 | tail -30
```
Expected: FAIL — `extra argument 'cardNumber' in call` (the init doesn't have the parameter yet).

- [ ] **Step 3: Change the `CardStepsViewModel` designated + convenience inits**

In `FenixKanban/Features/Card/CardStepsViewModel.swift`, replace the designated init (lines 35-40):

```swift
    init(card: Card, cardNumber: Int, client: FizzyClient, repository: StepRepository) {
        self.card = card
        self.cardNumber = cardNumber
        self.client = client
        self.repository = repository
    }
```

And the convenience init (lines 47-63) — pass the number straight through; the stub no longer needs `fizzyNumber`:

```swift
    convenience init(cardNumber: Int, client: FizzyClient) {
        // This path is only used by legacy call sites that don't have a Card
        // CoreData object. Create a temporary in-memory container so the
        // repository operations are safe.
        let tempController = PersistenceController(inMemory: true, useCloudKit: false)
        let context = tempController.viewContext
        // Create a stub card so the repository queries work
        let stubCard = Card(context: context)
        stubCard.id = UUID()
        stubCard.title = "stub"
        stubCard.createdAt = Date()
        stubCard.modifiedAt = Date()
        stubCard.sortOrder = 0
        try? context.save()
        self.init(card: stubCard, cardNumber: cardNumber, client: client, repository: StepRepository(context: context))
    }
```

- [ ] **Step 4: Compile-fix the CardDetailViewModel construction site (temporary)**

In `FenixKanban/Features/Card/CardDetailViewModel.swift`, line 61, update the construction so the app compiles (still reads the attribute — Task 3 replaces this with the resolved value):

```swift
            self.stepsViewModel = CardStepsViewModel(card: card, cardNumber: Int(card.fizzyNumber), client: client, repository: stepRepo)
```

- [ ] **Step 5: Run to verify the suite passes**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardStepsViewModelTests 2>&1 | tail -30
```
Expected: PASS (unchanged behavior — number now injected instead of derived inside the init).

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Card/CardStepsViewModel.swift \
        FenixKanban/Features/Card/CardDetailViewModel.swift \
        FenixKanbanTests/Features/Card/CardStepsViewModelTests.swift
git commit -m "refactor(#22): inject resolved card number into CardStepsViewModel"
```

---

### Task 3: `CardDetailViewModel` — store-first resolution

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` (append a new suite)

**Interfaces:**
- Consumes: `Card.resolvedFizzyNumber(_:)` (Task 1); `CardStepsViewModel(card:cardNumber:client:repository:)` (Task 2).
- Produces: `CardDetailViewModel(card:context:fizzyClient:currentFizzyUserID:pairingStore:)` (init gains `pairingStore: FizzyCardPairingStore = .shared`).

- [ ] **Step 1: Write the failing test**

Append to `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` (file scope, after the last suite):

```swift
@Suite("CardDetail Fizzy resolution (#22)", .serialized)
@MainActor
struct CardDetailFizzyResolutionTests {
    let mock = MockHTTPState()
    let persistence: PersistenceController
    let column: Column
    let client: FizzyClient

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
        client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: mock.makeSession(),
            clock: ImmediateClock()
        )
    }

    private func makeStore() -> FizzyCardPairingStore {
        FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
    }

    @Test("store pairing makes an attribute-unpaired card read as fizzy-paired")
    func storePairingDrivesFizzyState() throws {
        let card = CardRepository(context: persistence.viewContext).createCard(in: column, title: "C")
        // Attribute-unpaired: card.fizzyNumber defaults to 0.
        let store = makeStore()
        store.setPairing(
            FizzyCardPairing(fizzyID: "fz-7", fizzyNumber: 7, fizzyUpdatedAt: .now),
            for: card.id!
        )
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client, pairingStore: store)
        #expect(vm.isFizzyPaired)
        #expect(vm.stepsViewModel != nil)
    }

    @Test("attribute hint still reads as paired when the store is empty (cold-device fallback)")
    func attributeFallbackKeepsPaired() throws {
        let card = CardRepository(context: persistence.viewContext).createCard(in: column, title: "C")
        card.fizzyNumber = 7
        try persistence.viewContext.save()
        let store = makeStore()   // empty
        let vm = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client, pairingStore: store)
        #expect(vm.isFizzyPaired)
        #expect(vm.stepsViewModel != nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardDetailFizzyResolutionTests 2>&1 | tail -30
```
Expected: FAIL — `extra argument 'pairingStore' in call` (init lacks the parameter) and `storePairingDrivesFizzyState` would fail anyway (attribute-0 card currently reads unpaired).

- [ ] **Step 3: Add the stored property + init parameter + computed resolver**

In `FenixKanban/Features/Card/CardDetailViewModel.swift`:

(a) Add the stored property alongside the other repositories (after line 21, `private let labelRepository: LabelRepository`):

```swift
    private let pairingStore: FizzyCardPairingStore
```

(b) Replace the entire `init(...)` (lines 41-73) with:

```swift
    init(
        card: Card,
        context: NSManagedObjectContext,
        fizzyClient: FizzyClient? = nil,
        currentFizzyUserID: String? = nil,
        pairingStore: FizzyCardPairingStore = .shared
    ) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabels = card.labels as? Set<Label> ?? []
        self.assignees = card.assignees
        self.isWatched = card.isWatched
        self.isPinned = card.isPinned
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
        self.fizzyClient = fizzyClient
        self.pairingStore = pairingStore
        let resolvedNumber = card.resolvedFizzyNumber(pairingStore)
        if resolvedNumber > 0, let client = fizzyClient {
            let stepRepo = StepRepository(context: context)
            self.stepsViewModel = CardStepsViewModel(card: card, cardNumber: Int(resolvedNumber), client: client, repository: stepRepo)
            self.commentsViewModel = CardCommentsViewModel(
                cardFizzyNumber: resolvedNumber,
                client: client,
                context: context,
                currentFizzyUserID: currentFizzyUserID
            )
        } else {
            self.stepsViewModel = nil
            self.commentsViewModel = nil
        }
        observeCardChanges(context: context)
    }
```

(c) Add the computed resolver. Place it just above `isFizzyPaired` (currently line 170):

```swift
    /// Fizzy card number resolved store-first with CoreData-hint fallback (#22).
    private var resolvedFizzyNumber: Int64 { card.resolvedFizzyNumber(pairingStore) }
```

- [ ] **Step 4: Swap the remaining method-body reads**

Every remaining `card.fizzyNumber` in this file appears inside method bodies (the init no longer contains the literal; the doc-comments say `fizzyNumber > 0`, not `card.fizzyNumber`, so they're untouched). Replace **all** occurrences of the literal `card.fizzyNumber` with `resolvedFizzyNumber`:

Use Edit with `replace_all: true`, `old_string: "card.fizzyNumber"`, `new_string: "resolvedFizzyNumber"`.

This converts the guards and client-call arguments in `toggleLabel`, `isFizzyPaired`, `toggleAssignment`, `toggleWatched`, `togglePinned`, `toggleGolden`, `closeCard`, `reopenCard`, `postponeCard` (e.g. `guard resolvedFizzyNumber > 0, let client = fizzyClient else { return }` and `Int(resolvedFizzyNumber)`).

- [ ] **Step 5: Run the new suite + the existing CardDetail suites to verify pass + no regression**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/CardDetailFizzyResolutionTests \
  -only-testing:FenixKanbanTests/CardDetailViewModelTests 2>&1 | tail -40
```
Expected: all PASS (existing suites set both attribute and—where needed—exercise paired paths; the fallback keeps them paired).

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailViewModel.swift \
        FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift
git commit -m "feat(#22): resolve CardDetailViewModel fizzy state store-first"
```

---

### Task 4: `BoardViewModel` — store-first resolution

**Files:**
- Modify: `FenixKanban/Features/Board/BoardViewModel.swift` (init ~17-24; `pushGolden` ~126-129; `performLifecycleAction` ~181-189)
- Test: `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift` (append a test to `BoardViewModelGoldenPushTests`)

**Interfaces:**
- Consumes: `Card.resolvedFizzyNumber(_:)` (Task 1).
- Produces: `BoardViewModel(board:context:fizzyClient:pairingStore:)` (init gains `pairingStore: FizzyCardPairingStore = .shared`).

- [ ] **Step 1: Write the failing test**

Append a test inside the existing `BoardViewModelGoldenPushTests` suite in `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift`. It proves a card that is attribute-unpaired but present in the pairing store pushes goldness to the *store's* number:

```swift
    @Test("store pairing drives the board golden push for an attribute-unpaired card")
    func storePairingDrivesBoardPush() async throws {
        let store = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        // Fresh board + an attribute-unpaired card (fizzyNumber defaults to 0).
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B2")
        let col = boardRepo.createColumn(in: board, name: "C2")
        let storeCard = cardRepo.createCard(in: col, title: "StorePaired")
        try persistence.viewContext.save()
        store.setPairing(
            FizzyCardPairing(fizzyID: "fzS", fizzyNumber: 5, fizzyUpdatedAt: .now),
            for: storeCard.id!
        )

        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: mock.makeSession(), clock: ImmediateClock()
        )
        let vm = BoardViewModel(board: board, context: persistence.viewContext, fizzyClient: client, pairingStore: store)

        mock.handler = { request in (Data(), .response(for: request, status: 204)) }
        vm.toggleGolden(for: storeCard)
        var spins = 0
        while mock.requests.isEmpty && spins < 1000 { await Task.yield(); spins += 1 }
        let req = mock.requests.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path.hasSuffix("/cards/5/goldness") == true)   // store number, not attribute 0
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/BoardViewModelGoldenPushTests 2>&1 | tail -30
```
Expected: FAIL — `extra argument 'pairingStore' in call`; and once that compiles, the attribute-0 card would push nothing (no request).

- [ ] **Step 3: Add the stored property + init parameter**

In `FenixKanban/Features/Board/BoardViewModel.swift`, add the property after line 14 (`private let fizzyClient: FizzyClient?`):

```swift
    private let pairingStore: FizzyCardPairingStore
```

Replace the init signature + body opening (lines 17-22) to thread it in:

```swift
    init(board: Board, context: NSManagedObjectContext, fizzyClient: FizzyClient? = nil, pairingStore: FizzyCardPairingStore = .shared) {
        self.board = board
        self.context = context
        self.boardRepository = BoardRepository(context: context)
        self.cardRepository = CardRepository(context: context)
        self.fizzyClient = fizzyClient
        self.pairingStore = pairingStore
```

(Leave the rest of the init body — `refreshColumns()`, `observeChanges()`, etc. — unchanged.)

- [ ] **Step 4: Convert `pushGolden`**

Replace the guard + number lines in `pushGolden(for:)` (lines 127-129):

```swift
        let resolved = card.resolvedFizzyNumber(pairingStore)
        guard resolved > 0, let client = fizzyClient else { return }
        let isGolden = card.isGolden
        let number = Int(resolved)
```

(The downstream `number` usage is unchanged.)

- [ ] **Step 5: Convert `performLifecycleAction`**

Replace the guard + switch body in `performLifecycleAction` (lines 181-189):

```swift
            let resolved = card.resolvedFizzyNumber(pairingStore)
            guard resolved > 0, let client = fizzyClient else { return }
            let number = Int(resolved)
            do {
                switch action {
                case .close:
                    try await client.closeCard(number: number)
                case .reopen:
                    try await client.reopenCard(number: number)
                case .postpone:
                    try await client.postponeCard(number: number)
                }
```

- [ ] **Step 6: Run the board golden + lifecycle suites to verify pass + no regression**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/BoardViewModelGoldenPushTests \
  -only-testing:FenixKanbanTests/BoardViewModelGoldenTests \
  -only-testing:FenixKanbanTests/BoardViewModelLifecycleTests 2>&1 | tail -40
```
Expected: all PASS (existing paired tests set `card.fizzyNumber` with an empty store → fallback keeps them working; the new test proves store-first).

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Features/Board/BoardViewModel.swift \
        FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift
git commit -m "feat(#22): resolve BoardViewModel fizzy pushes store-first"
```

---

### Task 5: `FizzySyncProvider.retryPendingSteps` — store-first + expose `pairingStoreRef`

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (retry loop ~216-218; add accessor after line 266)
- Test: `FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift` (append a test)

**Interfaces:**
- Consumes: `Card.resolvedFizzyNumber(_:)` (Task 1); the provider already holds `pairingStore`.
- Produces: `var pairingStoreRef: FizzyCardPairingStore` (read accessor, consumed by Task 6).

- [ ] **Step 1: Write the failing test**

Append to `FizzySyncProviderTests` (inside the suite, after an existing test). It uses the file's private `Harness`:

```swift
    @Test("retryPendingSteps uses the store-resolved card number (not the attribute)")
    func retryPendingStepsResolvesStoreFirst() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")

        let ctx = h.persistence.viewContext
        let boardRepo = BoardRepository(context: ctx)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        let card = CardRepository(context: ctx).createCard(in: column, title: "C")
        // Attribute-unpaired (fizzyNumber 0); store says 5.
        let step = CardStep(context: ctx)
        step.fizzyStepID = "s1"
        step.content = "x"
        step.completed = false
        step.sortOrder = 0
        step.pendingWrite = true
        step.card = card
        try ctx.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzS", fizzyNumber: 5, fizzyUpdatedAt: .now),
            for: card.id!
        )

        h.mock.handler = { request in (Data("{}".utf8), .response(for: request, status: 200)) }
        await h.provider.retryPendingSteps()

        let req = try #require(h.mock.requests.first)
        #expect(req.url?.path.contains("/cards/5/") == true)   // store number, not attribute 0
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/FizzySyncProviderTests/retryPendingStepsResolvesStoreFirst 2>&1 | tail -30
```
Expected: FAIL — the attribute-0 card is skipped by the `card.fizzyNumber > 0` guard, so no request is issued (`#require` finds nil).

- [ ] **Step 3: Convert the retry loop**

In `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift`, replace the guard + number derivation (lines 216-218):

```swift
            guard !step.isDeleted, step.managedObjectContext != nil,
                  let card = step.card else { continue }
            let resolved = card.resolvedFizzyNumber(pairingStore)
            guard resolved > 0 else { continue }
            let cardNumber = Int(resolved)
```

(The rest of the loop, using `cardNumber`, is unchanged.)

- [ ] **Step 4: Expose `pairingStoreRef`**

After the existing `persistenceRef` accessor (line 266), add:

```swift
    var pairingStoreRef: FizzyCardPairingStore { pairingStore }
```

- [ ] **Step 5: Run to verify pass + provider regression check**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' \
  -only-testing:FenixKanbanTests/FizzySyncProviderTests 2>&1 | tail -40
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift \
        FenixKanbanTests/Features/Sync/Fizzy/FizzySyncProviderTests.swift
git commit -m "feat(#22): resolve retryPendingSteps store-first; expose pairingStoreRef"
```

---

### Task 6: `FizzyAuthStatusView.cardsSyncedCount` — store-backed count

The count is cosmetic and eventually-consistent (its own comment says so). Convert the `fizzyID != nil` NSPredicate count into a board-scoped fetch filtered by `resolvedFizzyID(store) != nil` (store-first, hint fallback as a superset — zero regression). This is a thin SwiftUI view; like the other view-only changes in this codebase (`CardView`, `FizzyBoardBrowserView`), it is verified by the build rather than a bespoke unit test.

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift:43-50`

**Interfaces:**
- Consumes: `Card.resolvedFizzyID(_:)` (Task 1); `FizzySyncProvider.pairingStoreRef` (Task 5).

- [ ] **Step 1: Replace `cardsSyncedCount`**

Replace lines 43-50:

```swift
    // Cards on the paired board with a known Fizzy pairing. Store-first with
    // the CoreData hint as fallback (#22): the device-local pairing store is
    // authoritative; the `fizzyID` hint answers only during the cold-device
    // pre-seed window. Cosmetic and eventually consistent (issue #21 A′).
    private var cardsSyncedCount: Int {
        guard let id = provider.mappingRef.localBoardID else { return 0 }
        let request: NSFetchRequest<Card> = Card.fetchRequest()
        request.predicate = NSPredicate(format: "column.board.id == %@", id as CVarArg)
        let store = provider.pairingStoreRef
        let cards = (try? provider.persistenceRef.viewContext.fetch(request)) ?? []
        return cards.filter { $0.resolvedFizzyID(store) != nil }.count
    }
```

- [ ] **Step 2: Build both platforms**

Run:
```bash
xcodebuild build -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB' 2>&1 | tail -20
xcodebuild build -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'generic/platform=macOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift
git commit -m "feat(#22): count synced cards from the pairing store, not the fizzyID hint"
```

---

### Task 7: Whole-suite + symbol sweep + macOS build verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit-test suite**

Run:
```bash
make test 2>&1 | tail -40
```
Expected: all tests pass. (If you hit `** TEST EXECUTE FAILED **` exit 65 with zero `✘` assertion-failure markers, that's the known simulator/teardown flake — re-run once. An actual `✘` is a real failure to fix.)

- [ ] **Step 2: SF Symbol validity sweep**

Run:
```bash
make symbols 2>&1 | tail -20
```
Expected: `TEST SUCCEEDED` (no phantom symbols — this change adds no `systemImage:` literals, but the sweep is the standing pre-push gate).

- [ ] **Step 3: macOS build**

Run:
```bash
xcodebuild build -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'generic/platform=macOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm the hint channel is untouched**

Run:
```bash
git diff origin/main --stat
grep -rn "seedPairingStoreFromHints\|healHints" FenixKanban --include="*.swift" | head
```
Expected: the diff touches only the files listed in Tasks 1-6 (plus `project.pbxproj`). `seedPairingStoreFromHints` / `healHints` still present and unmodified. No `.xcdatamodel` in the diff.

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-06-26-22-decouple-ui-reads-from-coredata-pairing-hints-design.md`):
- "Card+Pairing helper (store-first w/ fallback)" → Task 1. ✅
- "CardDetailViewModel — add pairingStore init, swap guards/construction reads" → Tasks 2 (steps seam) + 3. ✅
- "BoardViewModel — pushGolden, performLifecycleAction" → Task 4. ✅
- "CardStepsViewModel / CardCommentsViewModel — receive already-resolved number" → Task 2 (StepsVM init takes resolved number); CommentsViewModel needs no change (it only reads the passed-in `cardFizzyNumber`, resolved at the CardDetailViewModel construction site in Task 3). ✅
- "FizzySyncProvider — retry-pending-steps read" → Task 5. ✅
- "FizzyAuthStatusView — fizzyID != nil predicate/count → store-backed" → Task 6. ✅
- "Stays untouched: seed/heal, hint-writes, CoreData attributes, CardView:43" → no task modifies them; Task 7 Step 4 asserts it. ✅
- "Tests: helper both-branch + per-view-model store-wins/fallback" → Task 1 (3 cases), Task 3 (store-wins + fallback), Task 4 (store-wins; existing tests cover fallback), Task 5 (store-wins). ✅
- "Gate: make symbols + suites + macOS build" → Task 7. ✅

**2. Placeholder scan:** none — every code step carries full code; every run step carries an exact command + expected result.

**3. Type consistency:** `resolvedFizzyNumber(_:) -> Int64` and `resolvedFizzyID(_:) -> String?` (Task 1) are consumed with those exact signatures in Tasks 3-6. `CardStepsViewModel(card:cardNumber:client:repository:)` (Task 2) is called identically in Task 3's init. `pairingStore: FizzyCardPairingStore = .shared` init parameter shape is identical across CardDetailViewModel (Task 3) and BoardViewModel (Task 4). `pairingStoreRef` (Task 5) is read in Task 6. `FizzyCardPairing(fizzyID:fizzyNumber:fizzyUpdatedAt:)` and `setPairing(_:for:)` match the store API. Harness names (`MockHTTPState`, `mock.makeSession()`, `mock.handler`, `mock.requests`, `.response(for:status:)`, `ImmediateClock()`, `Harness`, `h.authState.setAccessToken/setAccountSlug`) match the existing test files verbatim.
