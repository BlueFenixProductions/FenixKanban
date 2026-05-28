# Fizzy Integration — Phase 4a: First-Sync Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `FizzySyncEngine` first-sync machinery — the one-shot operation that runs when a fresh board pair is established. Implements all three first-sync modes (push local to Fizzy / replace local with Fizzy / merge if no conflicts) and their field mappings. Steady-state diff + LWW conflict resolution land in Phase 4b.

**Architecture:** A `FizzySyncEngine` class composes the Phase 1-3 building blocks (`FizzyClient`, `FizzyAuthState`, `FizzyBoardMapping`, the v3 Card attributes). Engine accepts a `NSManagedObjectContext` and the auth/mapping types, plus a `FizzyClient` for HTTP. Public entry point: `syncFirst(mode:)` returns a `SyncResult`. Fully tested against a mocked `FizzyClient`; zero live network in CI.

**Tech Stack:** Swift 6 async/await, CoreData (`NSManagedObjectContext`), Swift Testing, `MockURLProtocol` from Phase 1, the Phase 2 `FizzyAuthState` / `FizzyBoardMapping`, the Phase 3 `Card.fizzyID/fizzyEtag/fizzyUpdatedAt` attributes.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md` (§ Sync cycle, § Field mapping, § First-sync direction)

**Splits Phase 4 into two plans:**
- **Phase 4a (this plan):** First-sync modes + foundation types. Ships an engine that can run once per pairing. Phase 5's UI binds to it for the "Pair and sync" button.
- **Phase 4b (follow-on):** Steady-state diff, LWW resolution, soft-delete, crash-after-POST recovery, tag/column auto-create-on-pull, idempotence, 401 handling.

**Out of scope for Phase 4a** (deferred to Phase 4b):
- Steady-state `sync()` call — the polling-triggered diff after a pair is established
- LWW conflict resolution (remote.updatedAt vs local.updatedAt)
- Soft-delete on missing-remote
- Crash-after-POST recovery (title + createdAt ±60s window)
- Tag/Label auto-create on pull (Phase 4a does naive name-match-or-skip)
- Idempotence guarantee + ETag persistence to `Card.fizzyEtag`
- 401 → `FizzyAuthState` clear + banner orchestration
- `FizzyBoardMapping.setLastSync(_:)` write at end of cycle (Phase 4b)

---

## Important spec divergences (called out explicitly)

These are MVP simplifications the spec implies but doesn't spell out. Each is flagged in the doc comments on the relevant code:

1. **Card ↔ Label cardinality mismatch.** Fizzy cards have `tags: [String]` (many); FenixKanban `Card.label` is a single optional relationship. Phase 4a maps **only the first remote tag** to the local Label on pull and **never pushes tags** (omits `tag_ids` from the Fizzy write payload). Lossy on tag-count and uni-directional on pushes; documented as a follow-up.

2. **Column matching is by name only.** No `fizzyColumnID` attribute on the local `Column` entity (would need a v4 migration). Phase 4a uses case-insensitive trimmed name matching. Documented as a known fragility — renaming a column on either side creates a phantom column on next sync. Phase 5 UI will warn the user.

3. **Pull does not auto-create remote columns.** Spec §"Field mapping" says local columns missing remotely are skipped with a SyncResult.errors entry. Phase 4a's `replace` and `merge` modes implement this as: any local card whose column has no remote match goes into an `errors` entry and is left unsynced. Phase 4a's `push` mode auto-creates remote cards regardless of local column (the cards go to the remote board; column placement is Fizzy's default "Maybe?").

4. **Pull DOES auto-create local columns.** Spec is explicit on this. Implemented in `findOrCreateLocalColumn(name:)`.

5. **Description format.** Phase 4a syncs `description: String?` only — Fizzy's `description_html` is ignored on pull, and the writer sends plain text. Documented as MVP.

---

## File Structure

**New source files:**
- `FenixKanban/Core/Services/Fizzy/FirstSyncMode.swift` — enum (3 cases, `Identifiable`, `CaseIterable` for Phase 5's Picker)
- `FenixKanban/Core/Services/Fizzy/SyncResult.swift` — value type returned by sync calls
- `FenixKanban/Core/Services/Fizzy/FizzySyncMapping.swift` — pure helpers (`labelColorHex(forName:)`, `normalizedColumnName(_:)`)
- `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` — the engine itself

**New test files:**
- `FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift`
- `FenixKanbanTests/Services/Fizzy/SyncResultTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzySyncMappingTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`

**No modifications** to existing source files. The engine consumes Phase 1-3 building blocks via injected dependencies; nothing currently calls it.

**`project.yml`:** no change — files land in existing tracked directories.

---

## Task 1: Foundation types — `FirstSyncMode` + `SyncResult` (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FirstSyncMode.swift`
- Create: `FenixKanban/Core/Services/Fizzy/SyncResult.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift`
- Create: `FenixKanbanTests/Services/Fizzy/SyncResultTests.swift`

Two small value types. Doing them in one task because each is ~20 LOC and the engine needs both.

- [ ] **Step 1: Write the failing tests**

Content (write to `FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FirstSyncMode")
struct FirstSyncModeTests {

    @Test("allCases order locks the picker order")
    func allCasesOrder() {
        #expect(FirstSyncMode.allCases == [.pushLocalToFizzy, .replaceLocalWithFizzy, .mergeIfNoConflicts])
    }

    @Test("raw value round-trips for every case")
    func rawValueRoundTrip() {
        for mode in FirstSyncMode.allCases {
            #expect(FirstSyncMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test("label strings are user-visible names")
    func labels() {
        #expect(FirstSyncMode.pushLocalToFizzy.label    == "Push local to Fizzy")
        #expect(FirstSyncMode.replaceLocalWithFizzy.label == "Replace local with Fizzy")
        #expect(FirstSyncMode.mergeIfNoConflicts.label   == "Merge if no conflicts")
    }
}
```

Content (write to `FenixKanbanTests/Services/Fizzy/SyncResultTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("SyncResult")
struct SyncResultTests {

    @Test("default init is all zeros, empty errors")
    func defaultInit() {
        let result = SyncResult()
        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("combine sums counters and concatenates errors")
    func combine() {
        let a = SyncResult(itemsCreated: 2, itemsUpdated: 1, itemsDeleted: 0, errors: ["err1"])
        let b = SyncResult(itemsCreated: 1, itemsUpdated: 3, itemsDeleted: 1, errors: ["err2"])
        let merged = a.combined(with: b)

        #expect(merged.itemsCreated == 3)
        #expect(merged.itemsUpdated == 4)
        #expect(merged.itemsDeleted == 1)
        #expect(merged.errors == ["err1", "err2"])
    }
}
```

- [ ] **Step 2: Regenerate + run failing tests**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FirstSyncModeTests \
  -only-testing:FenixKanbanTests/SyncResultTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FirstSyncMode` and `SyncResult` undefined.

- [ ] **Step 3: Implement `FirstSyncMode`**

Content (write to `FenixKanban/Core/Services/Fizzy/FirstSyncMode.swift`):

```swift
import Foundation

/// One-shot direction the user picks when establishing a Fizzy pairing.
///
/// Default is `.pushLocalToFizzy` — fizzy.bluefenix.net was empty when this
/// integration was built, and the common case is "I've been working in
/// FenixKanban and want my cards mirrored to Fizzy."
///
/// None of the three modes ever DELETEs remote cards — the closest is
/// `.replaceLocalWithFizzy`, which only deletes *local* state.
enum FirstSyncMode: String, CaseIterable, Identifiable {
    case pushLocalToFizzy
    case replaceLocalWithFizzy
    case mergeIfNoConflicts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushLocalToFizzy:      "Push local to Fizzy"
        case .replaceLocalWithFizzy: "Replace local with Fizzy"
        case .mergeIfNoConflicts:    "Merge if no conflicts"
        }
    }
}
```

- [ ] **Step 4: Implement `SyncResult`**

Content (write to `FenixKanban/Core/Services/Fizzy/SyncResult.swift`):

```swift
import Foundation

/// Outcome of a sync operation. Counters track per-card transitions; `errors`
/// carries human-readable warnings (e.g. "Local column 'Foo' has no Fizzy
/// match" or "Same-title collision: 'Buy milk'").
struct SyncResult: Equatable {
    var itemsCreated: Int = 0
    var itemsUpdated: Int = 0
    var itemsDeleted: Int = 0
    var errors: [String] = []

    /// Merges another result into a copy of this one. Used to combine the
    /// outcomes of multiple per-card or per-column passes within a single
    /// sync cycle.
    func combined(with other: SyncResult) -> SyncResult {
        SyncResult(
            itemsCreated: itemsCreated + other.itemsCreated,
            itemsUpdated: itemsUpdated + other.itemsUpdated,
            itemsDeleted: itemsDeleted + other.itemsDeleted,
            errors: errors + other.errors
        )
    }
}
```

- [ ] **Step 5: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FirstSyncModeTests \
  -only-testing:FenixKanbanTests/SyncResultTests \
  test 2>&1 | tail -10
```

Expected: 5 tests pass (3 + 2).

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FirstSyncMode.swift \
        FenixKanban/Core/Services/Fizzy/SyncResult.swift \
        FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift \
        FenixKanbanTests/Services/Fizzy/SyncResultTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FirstSyncMode enum + SyncResult value type

Three first-sync modes (push/replace/merge) the user picks when
establishing a pairing. SyncResult tracks created/updated/deleted
counters and human-readable errors with a .combined(with:) helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Do NOT commit the scheme file. If `make generate` modified it, `git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme` BEFORE staging.

---

## Task 2: Field-mapping helpers — `FizzySyncMapping` (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzySyncMapping.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzySyncMappingTests.swift`

Pure functions — no CoreData, no network. Decoupled from the engine so they're trivially unit-testable.

- [ ] **Step 1: Write the failing tests**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzySyncMappingTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzySyncMapping")
struct FizzySyncMappingTests {

    @Test("normalizedColumnName lowercases and trims")
    func normalizeColumnName() {
        #expect(FizzySyncMapping.normalizedColumnName("In Progress") == "in progress")
        #expect(FizzySyncMapping.normalizedColumnName("  TRIAGE ") == "triage")
        #expect(FizzySyncMapping.normalizedColumnName("review") == "review")
        #expect(FizzySyncMapping.normalizedColumnName("") == "")
    }

    @Test("labelColorHex is deterministic for the same name")
    func labelColorIsDeterministic() {
        #expect(FizzySyncMapping.labelColorHex(forName: "bug") == FizzySyncMapping.labelColorHex(forName: "bug"))
        #expect(FizzySyncMapping.labelColorHex(forName: "Bug") != FizzySyncMapping.labelColorHex(forName: "bug"),
                "Case-sensitive — \"Bug\" and \"bug\" produce different colors. Engine normalizes case at lookup time.")
    }

    @Test("labelColorHex returns a 7-char #RRGGBB string")
    func labelColorFormat() {
        let hex = FizzySyncMapping.labelColorHex(forName: "test-label")
        #expect(hex.count == 7)
        #expect(hex.hasPrefix("#"))
        // All chars after # must be 0-9 or A-F
        let body = String(hex.dropFirst())
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        #expect(body.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncMappingTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzySyncMapping` undefined.

- [ ] **Step 3: Implement `FizzySyncMapping`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzySyncMapping.swift`):

```swift
import Foundation

/// Pure helpers shared by the Fizzy sync engine: column-name normalization
/// for case-insensitive trimmed matching, and deterministic label-color
/// derivation so auto-created labels stay visually stable across reinstalls.
enum FizzySyncMapping {

    /// Lowercased + whitespace-trimmed name, used for matching local Columns
    /// to remote Fizzy columns. Phase 4a does not track `fizzyColumnID` on the
    /// local Column entity, so name-equality is the only join key — renaming
    /// a column on either side will produce a phantom local column on the
    /// next sync. Documented MVP limitation.
    static func normalizedColumnName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Deterministic `#RRGGBB` hex for an auto-created Label, derived from
    /// the tag name. Different reinstalls produce the same color for the
    /// same tag, so users get visual consistency.
    ///
    /// Uses a simple FNV-1a-ish hash over UTF-8 bytes mapped to 24 bits.
    /// Not Foundation's `String.hashValue` because that's randomized per
    /// process launch and would defeat determinism.
    static func labelColorHex(forName name: String) -> String {
        var hash: UInt32 = 0x811c9dc5  // FNV-1a 32-bit offset basis
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193  // FNV-1a 32-bit prime
        }
        let r = UInt8((hash >> 16) & 0xFF)
        let g = UInt8((hash >> 8)  & 0xFF)
        let b = UInt8(hash         & 0xFF)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
```

- [ ] **Step 4: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncMappingTests \
  test 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncMapping.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncMappingTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzySyncMapping — column normalize + label color hash

Pure helpers used by the sync engine. Column normalization lowercases
and whitespace-trims for case-insensitive matching. Label color uses
FNV-1a over UTF-8 bytes → 24-bit RGB so auto-created labels stay
visually stable across reinstalls (Foundation's hashValue is
process-randomized, would defeat determinism).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `FizzySyncEngine` skeleton + pairing precondition (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`

Engine init + public `syncFirst(mode:)` entry point with no actual sync logic yet — just the pairing-precondition early-return. Subsequent tasks add per-mode behavior.

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`):

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncEngine — pairing precondition", .serialized)
@MainActor
struct FizzySyncEnginePairingTests {

    @Test("syncFirst returns an empty SyncResult when unpaired")
    func unpairedReturnsEmpty() async throws {
        // Persistence + repos
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)

        // Auth + mapping using unique test prefixes/suites
        let authState = FizzyAuthState(keyPrefix: "test.fizzy.engine.\(UUID().uuidString)")
        defer { authState.clear() }
        let mappingDefaults = UserDefaults(suiteName: "test.fizzy.engine.mapping.\(UUID().uuidString)")!
        defer { mappingDefaults.removePersistentDomain(forName: "test.fizzy.engine.mapping.\(UUID().uuidString)") }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)

        // Engine — not paired
        let client = FizzyClient(
            baseURL: URL(string: "https://example.invalid")!,
            accessToken: "t",
            accountSlug: "ACCT"
        )
        let engine = FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext
        )

        let result = try await engine.syncFirst(mode: .pushLocalToFizzy)
        #expect(result == SyncResult())
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEnginePairingTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzySyncEngine` undefined.

- [ ] **Step 3: Implement `FizzySyncEngine` skeleton**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`):

```swift
import Foundation
import CoreData

/// Orchestrates one-shot first-sync runs between a paired local FenixKanban
/// board and the corresponding Fizzy board.
///
/// Composition is deliberate: the engine owns no Keychain or UserDefaults
/// access of its own — it consumes the Phase 2 `FizzyAuthState` and
/// `FizzyBoardMapping` instances injected at construction. Likewise, all
/// HTTP goes through `FizzyClient`. This keeps the engine fully testable
/// with `MockURLProtocol` and synthetic auth/mapping fixtures.
///
/// Phase 4a covers the three `FirstSyncMode` variants only. Steady-state
/// diff + LWW conflict resolution + soft-delete + 401 handling land in
/// Phase 4b.
@MainActor
final class FizzySyncEngine {

    private let client: FizzyClient
    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let context: NSManagedObjectContext

    init(
        client: FizzyClient,
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        context: NSManagedObjectContext
    ) {
        self.client = client
        self.authState = authState
        self.mapping = mapping
        self.context = context
    }

    /// One-shot first-sync. Caller must have set `authState.accessToken`,
    /// `authState.accountSlug`, `mapping.setPairing(...)` *before* invoking.
    /// Returns an empty `SyncResult` if any of those are missing.
    func syncFirst(mode: FirstSyncMode) async throws -> SyncResult {
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return SyncResult()
        }

        switch mode {
        case .pushLocalToFizzy:
            return try await syncFirstPushLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .replaceLocalWithFizzy:
            return try await syncFirstReplaceLocal(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        case .mergeIfNoConflicts:
            return try await syncFirstMerge(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        }
    }

    // MARK: - Mode implementations (skeleton — return empty in this task)

    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        SyncResult()  // Implemented in Task 4
    }

    private func syncFirstReplaceLocal(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        SyncResult()  // Implemented in Task 5
    }

    private func syncFirstMerge(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        SyncResult()  // Implemented in Task 6
    }

    // MARK: - Lookups

    private func fetchBoard(by id: NSManagedObjectID) -> Board? {
        try? context.existingObject(with: id) as? Board
    }
}
```

Note: `FizzyBoardMapping.localBoardID` returns `UUID?`, not `NSManagedObjectID`. We need a fetch-by-UUID. Update the `fetchBoard(by:)` helper:

```swift
    private func fetchBoard(by id: UUID) -> Board? {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
```

The `syncFirst` `guard` should call `fetchBoard(by: localBoardID)` where `localBoardID` is `UUID`.

- [ ] **Step 4: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEnginePairingTests \
  test 2>&1 | tail -10
```

Expected: 1 test passes. The unpaired-precondition path is exercised.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzySyncEngine skeleton + pairing precondition

@MainActor engine composes FizzyClient + FizzyAuthState +
FizzyBoardMapping + NSManagedObjectContext. syncFirst(mode:) returns
empty SyncResult when unpaired; per-mode bodies are stubs filled by
later tasks (4-6).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: First-sync mode 1 — Push local to Fizzy (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (flesh out `syncFirstPushLocal`)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (append `FizzySyncEnginePushLocalTests` suite)

The default mode the user picked. POSTs every local card on the paired board to Fizzy; stores returned `fizzyID` on each Card. If the remote board has pre-existing cards, those are LEFT untouched (Phase 4a doesn't pull them into local — that's Phase 4b's steady-state pull). Non-destructive.

- [ ] **Step 1: Append the failing test suite**

At the bottom of `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`, append:

```swift

@Suite("FizzySyncEngine — first-sync mode 1 (push local)", .serialized)
@MainActor
struct FizzySyncEnginePushLocalTests {

    /// Shared test harness — builds a paired board + engine wired to MockURLProtocol.
    private struct Harness {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: "Triage")
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.push.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.push.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t",
                accountSlug: "ACCT",
                urlSession: session,
                clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client,
                authState: authState,
                mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("push mode: 2 local cards + empty remote → 2 POSTs, returned IDs stored")
    func pushEmptyRemote() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card1 = h.cardRepo.createCard(in: h.column, title: "First")
        let card2 = h.cardRepo.createCard(in: h.column, title: "Second")
        try h.persistence.viewContext.save()

        // Configure mock: GET columns → empty array (so the engine learns there
        // are no remote cards to consider), then 2 POSTs each returning a
        // 201+Location followed by a single-card GET.
        var postCount = 0
        var nextFizzyID = 100
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let id = nextFizzyID
                nextFizzyID += 1
                let location = "https://fizzy.bluefenix.net/ACCT/cards/\(id)"
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                // Location-follow: return a synthetic card with the requested number/id
                let number = (p as NSString).lastPathComponent
                let body = """
                {
                  "id": "fzid-\(number)",
                  "number": \(number),
                  "title": "x",
                  "status": "published",
                  "description": null,
                  "description_html": null,
                  "image_url": null,
                  "has_attachments": false,
                  "tags": [],
                  "golden": false,
                  "last_active_at": "2026-05-25T00:00:00Z",
                  "created_at": "2026-05-25T00:00:00Z",
                  "url": "https://fizzy.bluefenix.net/ACCT/cards/\(number)"
                }
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(postCount == 2)
        #expect(result.itemsCreated == 2)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)

        h.persistence.viewContext.refresh(card1, mergeChanges: false)
        h.persistence.viewContext.refresh(card2, mergeChanges: false)
        #expect(card1.fizzyID != nil)
        #expect(card2.fizzyID != nil)
        #expect(card1.fizzyID != card2.fizzyID)
    }

    @Test("push mode: existing remote cards are left untouched, no new locals created")
    func pushNonEmptyRemoteIsNonDestructive() async throws {
        let h = Harness()
        defer { h.tearDown() }

        _ = h.cardRepo.createCard(in: h.column, title: "Local-only")
        try h.persistence.viewContext.save()

        // Mock: GET columns returns one column with one card already in it.
        // The push mode should ignore the existing remote cards (Phase 4a
        // doesn't pull on push — that's 4b's steady-state) and just POST
        // the local card.
        var postCount = 0
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/77"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/77"):
                let body = """
                {
                  "id": "fzid-77","number": 77,"title": "x","status": "published",
                  "description": null,"description_html": null,"image_url": null,
                  "has_attachments": false,"tags": [],"golden": false,
                  "last_active_at": "2026-05-25T00:00:00Z","created_at": "2026-05-25T00:00:00Z",
                  "url": "https://fizzy.bluefenix.net/ACCT/cards/77"
                }
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(postCount == 1, "push mode should POST only the local card")
        #expect(result.itemsCreated == 1)
        #expect(result.errors.isEmpty)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEnginePushLocalTests \
  test 2>&1 | tail -15
```

Expected: both tests fail. The current `syncFirstPushLocal` returns an empty `SyncResult` (no POSTs issued).

- [ ] **Step 3: Implement `syncFirstPushLocal` in `FizzySyncEngine.swift`**

Replace the existing stub body of `syncFirstPushLocal(localBoard:fizzyBoardID:)` with:

```swift
    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        // Push mode: POST every local card on the paired board. We don't
        // pull anything from remote in Phase 4a — pre-existing remote cards
        // (if any) stay untouched and become local cards in Phase 4b's
        // steady-state sync.
        var result = SyncResult()
        let cards = (localBoard.columns as? Set<Column>)?.flatMap { column in
            (column.cards as? Set<Card>) ?? []
        } ?? []

        for card in cards where card.fizzyID == nil {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }

    // MARK: - Card writes

    /// POSTs a local card to the remote board and returns the resulting
    /// `FizzyCard` (the client follows Location to fetch the full record).
    ///
    /// Phase 4a does not push `tag_ids` — see "Important spec divergences"
    /// in the plan. The Fizzy API treats `tag_ids` as optional; omitting it
    /// preserves whatever tags the server defaults to (none, for new cards).
    private func postCard(_ card: Card, toBoardID fizzyBoardID: String) async throws -> FizzyCard {
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: card.cardDescription,
                status: nil,
                tagIds: nil
            )
        )
        return try await client.post(
            "/boards/\(fizzyBoardID)/cards",
            body: payload,
            as: FizzyCard.self
        )
    }
```

- [ ] **Step 4: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEnginePushLocalTests \
  test 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): first-sync mode 1 — push local to Fizzy

POSTs every local card on the paired board; stores returned fizzyID
+ lastActiveAt on each Card. Non-destructive — existing remote cards
are left untouched (Phase 4b's steady-state will pull them).

Tags omitted from the POST payload per MVP scope; description is
pushed as plain text (no description_html on the wire).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: First-sync mode 2 — Replace local with Fizzy (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (flesh out `syncFirstReplaceLocal`)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (append suite)

Destructive on local side: deletes every card on the paired local board, then pulls the remote board's full state (columns + cards) into local. Auto-creates local columns + Labels as needed.

- [ ] **Step 1: Append the failing test suite**

At the bottom of `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`, append:

```swift

@Suite("FizzySyncEngine — first-sync mode 2 (replace local)", .serialized)
@MainActor
struct FizzySyncEngineReplaceLocalTests {

    private struct Harness {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let labelRepo: LabelRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
            labelRepo = LabelRepository(context: persistence.viewContext)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: "Triage")
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.replace.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.replace.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t",
                accountSlug: "ACCT",
                urlSession: session,
                clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client,
                authState: authState,
                mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    /// Mock handler that returns the given remote state.
    private static func mockBoardState(columnsJSON: String, cardsJSON: String) -> (URLRequest) throws -> (Data, HTTPURLResponse) {
        { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }
    }

    @Test("replace mode: 3 local cards deleted, 2 remote cards pulled into local")
    func replaceDestructivePull() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Local state: 3 cards
        _ = h.cardRepo.createCard(in: h.column, title: "Local A")
        _ = h.cardRepo.createCard(in: h.column, title: "Local B")
        _ = h.cardRepo.createCard(in: h.column, title: "Local C")
        try h.persistence.viewContext.save()

        // Remote state: 1 column + 2 cards
        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"Remote One","status":"published","description":"desc one","description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
          {"id":"fz2","number":2,"title":"Remote Two","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":["bug"],"golden":true,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
        ]
        """
        MockURLProtocol.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.itemsDeleted == 3)
        #expect(result.itemsCreated == 2)
        #expect(result.errors.isEmpty)

        // Verify local state matches remote
        let localCards = (h.column.cards as? Set<Card>) ?? []
        let titles = Set(localCards.compactMap(\.title))
        #expect(titles == Set(["Remote One", "Remote Two"]))

        // Verify golden flag was pulled
        let golden = localCards.first { $0.title == "Remote Two" }
        #expect(golden?.isGolden == true)

        // Verify a local Label was auto-created for the "bug" tag and attached
        #expect(golden?.label?.name == "bug")
    }

    @Test("replace mode: remote column missing locally → auto-created")
    func replaceAutoCreatesLocalColumn() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Remote has a column named "In Progress" that doesn't exist locally
        let columnsJSON = """
        [{"id":"FC2","name":"In Progress","color":{"name":"Lime","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = "[]"
        MockURLProtocol.handler = Self.mockBoardState(columnsJSON: columnsJSON, cardsJSON: cardsJSON)

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.errors.isEmpty)

        // Verify the column exists locally now
        let localColumnNames = Set(((h.board.columns as? Set<Column>) ?? []).compactMap(\.name))
        #expect(localColumnNames.contains("In Progress"))
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineReplaceLocalTests \
  test 2>&1 | tail -15
```

Expected: both tests fail.

- [ ] **Step 3: Implement `syncFirstReplaceLocal` + supporting helpers**

In `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`:

Replace the stub `syncFirstReplaceLocal(localBoard:fizzyBoardID:)` with:

```swift
    private func syncFirstReplaceLocal(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        var result = SyncResult()

        // 1. Wipe local cards on the paired board.
        let localCards = (localBoard.columns as? Set<Column>)?.flatMap { column in
            (column.cards as? Set<Card>) ?? []
        } ?? []
        for card in localCards {
            context.delete(card)
            result.itemsDeleted += 1
        }

        // 2. Pull remote columns + cards.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        // 3. Auto-create local columns for any remote name not seen.
        let localColumnsByName = Dictionary(
            uniqueKeysWithValues: ((localBoard.columns as? Set<Column>) ?? []).compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )

        var resolvedColumns = localColumnsByName
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let newColumn = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = newColumn
            }
        }

        // 4. Create local cards mirroring each remote.
        for remote in remoteCards {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)

            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }

    // MARK: - Remote fetches

    private func fetchRemoteColumns(boardID: String) async throws -> [FizzyColumn] {
        try await client.get("/boards/\(boardID)/columns", as: [FizzyColumn].self)
    }

    /// Fetches all cards for a remote board via the per-board list endpoint
    /// `GET /:account/cards?board_ids[]=<id>`. Phase 4a uses the list shape
    /// (no `column` field per Fizzy docs) — column placement is recovered
    /// from each card's column relationship on a follow-up GET if needed.
    /// For the first-sync modes we accept "no column" → drop into the
    /// first available column.
    private func fetchRemoteCards(boardID: String) async throws -> [FizzyCard] {
        try await client.get("/cards?board_ids[]=\(boardID)", as: [FizzyCard].self)
    }

    // MARK: - Apply remote → local

    /// Writes the synced fields from a `FizzyCard` onto a local `Card`.
    /// Phase 4a maps only the first remote tag to `Card.label`; remaining
    /// tags are dropped (documented limitation).
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        card.cardDescription = remote.description
        card.isGolden = remote.golden
        card.fizzyID = remote.id
        card.fizzyUpdatedAt = remote.lastActiveAt

        if let firstTag = remote.tags.first {
            card.label = findOrCreateLabel(name: firstTag)
        } else {
            card.label = nil
        }
    }

    /// Finds a `Label` by case-insensitive name or creates one with a
    /// deterministic color derived from the name.
    private func findOrCreateLabel(name: String) -> Label {
        let request: NSFetchRequest<Label> = Label.fetchRequest()
        request.predicate = NSPredicate(format: "name ==[c] %@", name)
        request.fetchLimit = 1
        if let existing = (try? context.fetch(request))?.first {
            return existing
        }
        let colorHex = FizzySyncMapping.labelColorHex(forName: name)
        return LabelRepository(context: context).createLabel(name: name, colorHex: colorHex)
    }
```

- [ ] **Step 4: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineReplaceLocalTests \
  test 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): first-sync mode 2 — replace local with Fizzy

Destructive on local: wipes paired-board cards, then pulls remote
columns + cards. Auto-creates local columns for any unseen remote
name; first remote tag → local Label (auto-created with FNV-1a
deterministic color). Phase 4b will add the steady-state pull
that follows; this is the one-shot replace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: First-sync mode 3 — Merge if no conflicts (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (flesh out `syncFirstMerge`)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (append suite)

Bidirectional additive: pushes local-only cards (those with `nil fizzyID`) and pulls remote-only cards. If a local card and a remote card share the same case-insensitive title, that's a collision — logged to `SyncResult.errors`, NEITHER side is touched, both keep their independent existence.

- [ ] **Step 1: Append the failing test suite**

At the bottom of `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`, append:

```swift

@Suite("FizzySyncEngine — first-sync mode 3 (merge)", .serialized)
@MainActor
struct FizzySyncEngineMergeTests {

    private struct Harness {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let suiteName: String
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults

        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)
            boardRepo = BoardRepository(context: persistence.viewContext)
            cardRepo = CardRepository(context: persistence.viewContext)
            board = boardRepo.createBoard(name: "Roadmap")
            column = boardRepo.createColumn(in: board, name: "Triage")
            try! persistence.viewContext.save()

            let prefix = "test.fizzy.merge.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.merge.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t",
                accountSlug: "ACCT",
                urlSession: session,
                clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client,
                authState: authState,
                mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("merge mode: no title overlap → 2 POSTs + 2 local creates, no errors")
    func mergeNoOverlap() async throws {
        let h = Harness()
        defer { h.tearDown() }

        _ = h.cardRepo.createCard(in: h.column, title: "Local A")
        _ = h.cardRepo.createCard(in: h.column, title: "Local B")
        try h.persistence.viewContext.save()

        var postCount = 0
        var nextNumber = 100

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [
                  {"id":"fzR1","number":1,"title":"Remote X","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
                  {"id":"fzR2","number":2,"title":"Remote Y","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
                ]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let n = nextNumber
                nextNumber += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(n)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let n = (p as NSString).lastPathComponent
                let body = """
                {"id":"fz-\(n)","number":\(n),"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/\(n)"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(postCount == 2, "both local cards pushed")
        #expect(result.itemsCreated == 4, "2 POSTs + 2 local creates from remote")
        #expect(result.errors.isEmpty)

        let localTitles = Set(((h.column.cards as? Set<Card>) ?? []).compactMap(\.title))
        #expect(localTitles == Set(["Local A", "Local B", "Remote X", "Remote Y"]))
    }

    @Test("merge mode: title collision → SyncResult.errors entry, neither side merged")
    func mergeWithTitleCollision() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let collidingLocal = h.cardRepo.createCard(in: h.column, title: "Shared title")
        _ = h.cardRepo.createCard(in: h.column, title: "Only local")
        try h.persistence.viewContext.save()

        var postCount = 0
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [
                  {"id":"fzR1","number":1,"title":"Shared title","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/1"},
                  {"id":"fzR2","number":2,"title":"Only remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/2"}
                ]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/99"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let n = (p as NSString).lastPathComponent
                let body = """
                {"id":"fz-\(n)","number":\(n),"title":"Only local","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/\(n)"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected request: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(postCount == 1, "only Only local is pushed; Shared title is skipped due to collision")
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains("Shared title") == true)

        // The colliding local card keeps its nil fizzyID — unmerged.
        h.persistence.viewContext.refresh(collidingLocal, mergeChanges: false)
        #expect(collidingLocal.fizzyID == nil)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineMergeTests \
  test 2>&1 | tail -15
```

Expected: both tests fail (stub returns empty `SyncResult`).

- [ ] **Step 3: Implement `syncFirstMerge`**

Replace the stub `syncFirstMerge(localBoard:fizzyBoardID:)` with:

```swift
    private func syncFirstMerge(localBoard: Board, fizzyBoardID: String) async throws -> SyncResult {
        var result = SyncResult()

        // Fetch both sides.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        let localCards = (localBoard.columns as? Set<Column>)?.flatMap { column in
            (column.cards as? Set<Card>) ?? []
        } ?? []

        // Lower-cased title sets for collision detection.
        let localTitles = Set(localCards.compactMap { $0.title?.lowercased() })
        let remoteTitlesLower = Set(remoteCards.map { $0.title.lowercased() })

        // Collisions = title appears on BOTH sides. Skipped entirely (neither side touched).
        let collisions = localTitles.intersection(remoteTitlesLower)
        for collidingTitle in collisions {
            result.errors.append("Same-title collision: '\(collidingTitle)'")
        }

        // Auto-create local columns for any remote name not seen (so we have somewhere to drop pulls).
        var resolvedColumns = Dictionary(
            uniqueKeysWithValues: ((localBoard.columns as? Set<Column>) ?? []).compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let newColumn = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = newColumn
            }
        }

        // Pull remote-only cards (not in local, not a collision).
        for remote in remoteCards where !localTitles.contains(remote.title.lowercased()) {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)
            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // Push local-only cards (nil fizzyID, not a collision).
        for card in localCards where card.fizzyID == nil
                                && !remoteTitlesLower.contains(card.title?.lowercased() ?? "") {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }

        if context.hasChanges {
            try context.save()
        }
        return result
    }
```

- [ ] **Step 4: Run tests + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineMergeTests \
  test 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 5: Run the FULL Fizzy suite to confirm no regressions**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FirstSyncModeTests \
  -only-testing:FenixKanbanTests/SyncResultTests \
  -only-testing:FenixKanbanTests/FizzySyncMappingTests \
  -only-testing:FenixKanbanTests/FizzySyncEnginePairingTests \
  -only-testing:FenixKanbanTests/FizzySyncEnginePushLocalTests \
  -only-testing:FenixKanbanTests/FizzySyncEngineReplaceLocalTests \
  -only-testing:FenixKanbanTests/FizzySyncEngineMergeTests \
  test 2>&1 | grep -E "Test run|TEST" | tail -3
```

Expected: 13 tests pass total (5+3+1+2+2 = 13 across the 7 Phase 4a suites).

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): first-sync mode 3 — merge if no conflicts

Additive bidirectional merge. Local-only cards (nil fizzyID, no
title collision) get POSTed. Remote-only cards (no matching local
title) get created locally. Title collisions logged to
SyncResult.errors — neither side touched, both retain independence.

Title matching is case-insensitive; this is a fragility, but
Phase 4b's steady-state diff (using fizzyID, not title) is the
canonical join after first-sync.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Document Phase 4a in `TDD_IMPLEMENTATION_STATUS.md`

**File:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md`

- [ ] **Step 1: Append the entry**

Append to the bottom of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown

### Fizzy Integration — Phase 4a: First-Sync Engine ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- Wrote tests for `FirstSyncMode` (3) and `SyncResult` (2) — type-level contracts.
- Wrote `FizzySyncMappingTests` (3) — pure-function helpers: column normalize + label color hash (FNV-1a deterministic, 24-bit RGB).
- Wrote `FizzySyncEngineTests` (5) covering: pairing precondition fallthrough; mode 1 (push to empty / non-empty remote); mode 2 (destructive replace + column auto-create); mode 3 (no overlap + title collision).
- All tests verified failing before implementation.

**🟢 Green Phase:**
- `FenixKanban/Core/Services/Fizzy/FirstSyncMode.swift` — enum with 3 cases, `CaseIterable`/`Identifiable`/`RawRepresentable`.
- `FenixKanban/Core/Services/Fizzy/SyncResult.swift` — value type with counters + errors + `combined(with:)` helper.
- `FenixKanban/Core/Services/Fizzy/FizzySyncMapping.swift` — `normalizedColumnName` (lowercase + trim) + `labelColorHex` (FNV-1a → `#RRGGBB`).
- `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` — `@MainActor` engine composing `FizzyClient`/`FizzyAuthState`/`FizzyBoardMapping`/`NSManagedObjectContext`. `syncFirst(mode:)` dispatches to:
  - `.pushLocalToFizzy` → POST every local card, store returned `fizzyID`. Non-destructive on remote.
  - `.replaceLocalWithFizzy` → delete all local cards on paired board, pull remote columns + cards. Auto-creates local columns + Labels.
  - `.mergeIfNoConflicts` → push local-only, pull remote-only, log title collisions to `SyncResult.errors`.

**🔵 Refactor Phase:**
- Field mapping centralized in `applyRemote(_:to:)` (used by replace + future steady-state pull) and `postCard(_:toBoardID:)` (used by push + merge + future steady-state push).
- Column resolution centralized in a single `resolvedColumns: [String: Column]` dictionary, keyed by `normalizedColumnName`.
- Tag → Label mapping uses `findOrCreateLabel(name:)` with case-insensitive name match.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-4a-first-sync.md`

**Test Coverage:** 13 new tests across 7 suites. Full suite green.

**Documented MVP limitations** (also flagged in source comments):
1. Card.label is single-valued; only the first remote tag is mapped on pull. Push omits `tag_ids` entirely.
2. Column matching is by case-insensitive name only — no `fizzyColumnID` attribute on local Column. Renaming a column on either side creates a phantom column on next sync.
3. `description` synced as plain text; `description_html` ignored on pull.

**What ships:** A one-shot first-sync engine usable by Phase 5's `FizzyAuthView` "Pair and sync" button. Phase 4b adds steady-state diff, LWW resolution, soft-delete, crash-after-POST recovery, idempotence, and 401 handling.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 4a (first-sync engine)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Final verification

- [ ] **Step 1: Reset simulator + run full iOS test suite**

```bash
xcrun simctl shutdown all 2>&1 | tail -1
sleep 3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with 186 tests in ~45 suites passed` (Phase 3 baseline 173 + Phase 4a added 13). If a test regressed, the most likely culprit is the engine's CoreData mutations leaking outside its harness; check `Harness.tearDown()` is called via `defer`.

- [ ] **Step 2: Clean macOS build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 3: Verify branch state**

```bash
git log --oneline 88b5d05..HEAD  # 88b5d05 = Phase 3 plan commit; this shows all Phase 3 + 4a work
git status -sb
```

Expected: clean working tree, branch ahead of origin.

- [ ] **Step 4: Report ready-for-PR**

Phase 4a ships independently. Suggested PR title if/when you push:

> `feat(fizzy): Phase 4a — first-sync engine (push / replace / merge)`

Suggested PR body skeleton (do NOT auto-push):

```markdown
## Summary
- New `FizzySyncEngine` with `syncFirst(mode:)` covering three first-sync modes.
- Default mode: `.pushLocalToFizzy` (FenixKanban → Fizzy), matching the empty-Fizzy starting state.
- 13 new tests; full suite green at 186/186.
- Engine is fully testable against `MockURLProtocol`; no live network in CI.
- Not yet wired to the app — Phase 5's `FizzyAuthView` will call `syncFirst(mode:)` from the "Pair and sync" button.

## Test plan
- [x] Build clean on iOS Simulator + macOS.
- [x] 13 new tests cover all three modes + pairing precondition + mapping helpers.
- [x] Full suite green.

## Documented MVP limitations
- Card.label is single-valued — only the first remote tag is pulled, and tags are not pushed.
- Column matching is by case-insensitive name; no fizzyColumnID yet.
- description_html is dropped on pull; description pushed as plain text.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-4a-first-sync.md`
- Phase 4b (steady-state) is the natural follow-on once this lands.
```

---

## Success criteria recap

- [ ] `FirstSyncMode`, `SyncResult`, `FizzySyncMapping`, `FizzySyncEngine` exist at the spec'd paths.
- [ ] 13 new tests pass across 7 suites.
- [ ] Full iOS test suite passes (~186 tests).
- [ ] macOS clean build succeeds.
- [ ] `syncFirst(mode:)` is the only public engine method; per-mode bodies are private.
- [ ] All three modes write `fizzyID` + `fizzyUpdatedAt` on newly-paired cards.
- [ ] Tests use `Harness` value types with `defer { tearDown() }` to keep Keychain + UserDefaults state isolated.
- [ ] `TDD_IMPLEMENTATION_STATUS.md` updated with the 4a entry.
- [ ] No app wiring — Phase 5 binds this to the UI.
