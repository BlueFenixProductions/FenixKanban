# Multi-board pairing — Phase 7a (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-board `FizzyBoardMapping` singleton with a device-local multi-pairing store, route the sync engine/provider/scheduler per board, and silently migrate the existing pairing — all behind the existing UI, with zero UX change.

**Architecture:** A new device-local `FizzyBoardPairingStore` (JSON sidecar in Application Support, mirroring `FizzyCardPairingStore`) holds an ordered list of `FizzyBoardPairing`. The sync engine's public guards take a `localBoardID` and look the board up in the store; the provider routes the `BoardSyncProvider.sync(boardId:)` param to the matching pairing; the scheduler iterates `syncEnabled` pairings serial round-robin, frontmost board first. The legacy single pairing auto-migrates to row 1 so the unchanged single-pair UI keeps working.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), CoreData, `MockURLProtocol` for HTTP, `os.Logger`.

## Global Constraints

- Swift Testing only (NOT XCTest); suites that call `context.save()` on a viewContext MUST be `@MainActor` (matches every other such suite in the repo).
- The pairing store is **device-local** — JSON sidecar in Application Support, **never** CloudKit. Mirror `FizzyCardPairingStore` exactly (atomic write, `NSLock`, injectable `fileURL`, a missing/unreadable file is an empty store).
- Tests MUST inject a private `fileURL` (temp dir) and a private `UserDefaults(suiteName:)` — never touch the real sidecar or `.standard` defaults.
- Serial round-robin sync only — one engine instance active at a time; preserve the engine's `isSyncing` reentrancy guard.
- Unpair clears the pairing row only and **never** touches `Card` data (existing `changePairing` contract).
- Commit after every green step. Stage specific files (NO `git add -A`). Do NOT add a `Co-Authored-By` trailer (the repo's commit classifier rejects it).
- Branch: `claude/18-multi-board-pairing` (already created; the design spec commit `ed94283` is its tip).

---

### Task 1: `FizzyBoardPairingStore` + `FizzyBoardPairing` model

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyBoardPairingStore.swift`
- Test: `FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreTests.swift`

**Interfaces:**
- Consumes: nothing (new leaf).
- Produces:
  - `struct FizzyBoardPairing: Codable, Equatable { var localBoardID: UUID; var fizzyBoardID: String; var fizzyBoardName: String?; var lastSyncAt: Date?; var etag: String?; var syncEnabled: Bool }` with a memberwise init defaulting `fizzyBoardName=nil, lastSyncAt=nil, etag=nil, syncEnabled=true`.
  - `final class FizzyBoardPairingStore: @unchecked Sendable` with: `static let shared`; `init(fileURL: URL = defaultFileURL)`; `var isEmpty: Bool`; `var count: Int`; `func all() -> [FizzyBoardPairing]` (insertion order); `func pairing(forLocal: UUID) -> FizzyBoardPairing?`; `func pairing(forFizzy: String) -> FizzyBoardPairing?`; `func upsert(_:)`; `func setLastSync(localBoardID: UUID, _ date: Date)`; `func setSyncEnabled(localBoardID: UUID, _ enabled: Bool)`; `func remove(localBoardID: UUID)`; `func clearAll()`.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardPairingStore")
struct FizzyBoardPairingStoreTests {

    /// Hermetic store backed by a unique temp file (never the real sidecar).
    private func makeStore() -> FizzyBoardPairingStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-\(UUID().uuidString).json")
        return FizzyBoardPairingStore(fileURL: url)
    }

    @Test("upsert inserts then updates in place, preserving order")
    func upsertInsertsThenUpdates() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fb"))
        #expect(store.all().map(\.localBoardID) == [a, b])

        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa2"))
        #expect(store.all().map(\.localBoardID) == [a, b])           // order kept
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fa2")    // value replaced
    }

    @Test("lookups by local and fizzy id")
    func lookups() {
        let store = makeStore()
        let a = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fa")
        #expect(store.pairing(forFizzy: "fa")?.localBoardID == a)
        #expect(store.pairing(forLocal: UUID()) == nil)
    }

    @Test("setLastSync and setSyncEnabled mutate the row")
    func mutators() {
        let store = makeStore()
        let a = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        let when = Date(timeIntervalSince1970: 1_000)
        store.setLastSync(localBoardID: a, when)
        store.setSyncEnabled(localBoardID: a, false)
        #expect(store.pairing(forLocal: a)?.lastSyncAt == when)
        #expect(store.pairing(forLocal: a)?.syncEnabled == false)
    }

    @Test("remove and clearAll")
    func removal() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fb"))
        store.remove(localBoardID: a)
        #expect(store.all().map(\.localBoardID) == [b])
        store.clearAll()
        #expect(store.isEmpty)
    }

    @Test("persists across instances on the same file")
    func persistence() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-\(UUID().uuidString).json")
        let a = UUID()
        do {
            let store = FizzyBoardPairingStore(fileURL: url)
            store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa", fizzyBoardName: "Sandbox"))
        }
        let reopened = FizzyBoardPairingStore(fileURL: url)
        #expect(reopened.pairing(forLocal: a)?.fizzyBoardName == "Sandbox")
    }

    @Test("missing file is an empty store")
    func missingFileEmpty() {
        let store = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID()).json")
        )
        #expect(store.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardPairingStoreTests`
Expected: FAIL to compile — `FizzyBoardPairingStore` / `FizzyBoardPairing` undefined.

- [ ] **Step 3: Write the implementation**

Create `FenixKanban/Core/Services/Fizzy/FizzyBoardPairingStore.swift`:

```swift
import Foundation
import os

/// One local board's pairing with its Fizzy twin (Phase 7, issue #18).
struct FizzyBoardPairing: Codable, Equatable {
    var localBoardID: UUID
    var fizzyBoardID: String
    var fizzyBoardName: String?
    var lastSyncAt: Date?
    var etag: String?
    var syncEnabled: Bool

    init(
        localBoardID: UUID,
        fizzyBoardID: String,
        fizzyBoardName: String? = nil,
        lastSyncAt: Date? = nil,
        etag: String? = nil,
        syncEnabled: Bool = true
    ) {
        self.localBoardID = localBoardID
        self.fizzyBoardID = fizzyBoardID
        self.fizzyBoardName = fizzyBoardName
        self.lastSyncAt = lastSyncAt
        self.etag = etag
        self.syncEnabled = syncEnabled
    }
}

/// Device-local, insertion-ordered store of board pairings (issue #18).
///
/// Like `FizzyCardPairingStore`, pairing is device-truth, not document-truth:
/// it must live where CloudKit's multi-device merges cannot duplicate it
/// (issues #21/#22). Backed by a JSON sidecar written atomically on every
/// mutation; a missing or unreadable file is an empty store.
final class FizzyBoardPairingStore: @unchecked Sendable {

    static let shared = FizzyBoardPairingStore()

    let fileURL: URL
    private let lock = NSLock()
    private var pairings: [FizzyBoardPairing]   // insertion-ordered
    private static let logger = Logger(
        subsystem: "com.bluefenixproductions.FenixKanban",
        category: "FizzyBoardPairingStore"
    )

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FenixKanban", directoryHint: .isDirectory)
            .appending(path: "FizzyBoardPairings.json")
    }

    init(fileURL: URL = FizzyBoardPairingStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([FizzyBoardPairing].self, from: data) {
            pairings = decoded
        } else {
            pairings = []
        }
    }

    var isEmpty: Bool { lock.withLock { pairings.isEmpty } }
    var count: Int { lock.withLock { pairings.count } }

    func all() -> [FizzyBoardPairing] { lock.withLock { pairings } }

    func pairing(forLocal id: UUID) -> FizzyBoardPairing? {
        lock.withLock { pairings.first { $0.localBoardID == id } }
    }

    func pairing(forFizzy id: String) -> FizzyBoardPairing? {
        lock.withLock { pairings.first { $0.fizzyBoardID == id } }
    }

    func upsert(_ pairing: FizzyBoardPairing) {
        lock.withLock {
            if let i = pairings.firstIndex(where: { $0.localBoardID == pairing.localBoardID }) {
                pairings[i] = pairing
            } else {
                pairings.append(pairing)
            }
            persistLocked()
        }
    }

    func setLastSync(localBoardID id: UUID, _ date: Date) {
        lock.withLock {
            guard let i = pairings.firstIndex(where: { $0.localBoardID == id }) else { return }
            pairings[i].lastSyncAt = date
            persistLocked()
        }
    }

    func setSyncEnabled(localBoardID id: UUID, _ enabled: Bool) {
        lock.withLock {
            guard let i = pairings.firstIndex(where: { $0.localBoardID == id }) else { return }
            pairings[i].syncEnabled = enabled
            persistLocked()
        }
    }

    func remove(localBoardID id: UUID) {
        lock.withLock {
            let before = pairings.count
            pairings.removeAll { $0.localBoardID == id }
            if pairings.count != before { persistLocked() }
        }
    }

    func clearAll() {
        lock.withLock {
            guard !pairings.isEmpty else { return }
            pairings = []
            persistLocked()
        }
    }

    /// Must be called with `lock` held. Atomic write. Default Codable Date
    /// representation keeps exact fidelity (do NOT switch to .iso8601).
    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(pairings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("board pairing store persist failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardPairingStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyBoardPairingStore.swift FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreTests.swift
git commit -m "feat(#18): device-local FizzyBoardPairingStore"
```

---

### Task 2: Silent legacy migration (singleton → row 1)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyBoardPairingStore.swift` (add migration method)
- Test: `FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreMigrationTests.swift`

**Interfaces:**
- Consumes: `FizzyBoardPairingStore.upsert(_:)`, `FizzyBoardPairing` (Task 1).
- Produces: `@discardableResult func migrateLegacyMappingIfNeeded(defaults: UserDefaults = .standard) -> Bool` on `FizzyBoardPairingStore` — returns `true` only when a legacy pairing was folded in this call.

The legacy `FizzyBoardMapping` wrote three `UserDefaults` keys: `"fizzy.pairing.localBoardID"` (UUID string), `"fizzy.pairing.fizzyBoardID"` (String), `"fizzy.pairing.lastSyncAt"` (ISO8601 string). The migration reads them directly, folds them into row 1, then deletes them. Guarded by `"fizzy.pairing.migratedToBoardStore.v1"`.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreMigrationTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardPairingStore migration")
struct FizzyBoardPairingStoreMigrationTests {

    private func makeStore() -> FizzyBoardPairingStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-mig-\(UUID().uuidString).json")
        return FizzyBoardPairingStore(fileURL: url)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fbps-mig-\(UUID().uuidString)")!
    }

    @Test("folds the legacy singleton into row 1 and clears legacy keys")
    func foldsLegacy() {
        let store = makeStore()
        let defaults = makeDefaults()
        let local = UUID()
        defaults.set(local.uuidString, forKey: "fizzy.pairing.localBoardID")
        defaults.set("fz-123", forKey: "fizzy.pairing.fizzyBoardID")
        defaults.set(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 5_000)),
                     forKey: "fizzy.pairing.lastSyncAt")

        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == true)

        let row = store.pairing(forLocal: local)
        #expect(row?.fizzyBoardID == "fz-123")
        #expect(row?.lastSyncAt == Date(timeIntervalSince1970: 5_000))
        #expect(store.all().count == 1)
        // Legacy keys cleared:
        #expect(defaults.string(forKey: "fizzy.pairing.localBoardID") == nil)
        #expect(defaults.string(forKey: "fizzy.pairing.fizzyBoardID") == nil)
    }

    @Test("is idempotent — second call is a no-op")
    func idempotent() {
        let store = makeStore()
        let defaults = makeDefaults()
        defaults.set(UUID().uuidString, forKey: "fizzy.pairing.localBoardID")
        defaults.set("fz-123", forKey: "fizzy.pairing.fizzyBoardID")

        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == true)
        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == false)
        #expect(store.all().count == 1)
    }

    @Test("fresh install with no legacy keys is a no-op")
    func freshNoOp() {
        let store = makeStore()
        let defaults = makeDefaults()
        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == false)
        #expect(store.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardPairingStoreMigrationTests`
Expected: FAIL to compile — `migrateLegacyMappingIfNeeded` undefined.

- [ ] **Step 3: Write the implementation**

Append to `FizzyBoardPairingStore` (inside the class, after `clearAll()`):

```swift
    /// One-time, idempotent fold of the legacy `FizzyBoardMapping` singleton
    /// (three `UserDefaults` keys) into row 1. Writes the new row BEFORE
    /// deleting the legacy keys, so a crash mid-migration never loses the
    /// pairing. Returns `true` only when a legacy pairing was folded in.
    @discardableResult
    func migrateLegacyMappingIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let migratedKey = "fizzy.pairing.migratedToBoardStore.v1"
        guard !defaults.bool(forKey: migratedKey) else { return false }

        let localKey = "fizzy.pairing.localBoardID"
        let fizzyKey = "fizzy.pairing.fizzyBoardID"
        let lastSyncKey = "fizzy.pairing.lastSyncAt"

        guard let localStr = defaults.string(forKey: localKey),
              let localID = UUID(uuidString: localStr),
              let fizzyID = defaults.string(forKey: fizzyKey) else {
            defaults.set(true, forKey: migratedKey)   // nothing to migrate; don't recheck
            return false
        }

        let lastSync = defaults.string(forKey: lastSyncKey)
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        upsert(FizzyBoardPairing(
            localBoardID: localID,
            fizzyBoardID: fizzyID,
            lastSyncAt: lastSync
        ))   // new row persisted to sidecar first

        defaults.removeObject(forKey: localKey)
        defaults.removeObject(forKey: fizzyKey)
        defaults.removeObject(forKey: lastSyncKey)
        defaults.set(true, forKey: migratedKey)
        return true
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyBoardPairingStoreMigrationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyBoardPairingStore.swift FenixKanbanTests/Services/Fizzy/FizzyBoardPairingStoreMigrationTests.swift
git commit -m "feat(#18): silent legacy-mapping migration into row 1"
```

---

### Task 3: `FizzySyncEngine` per-board guard refactor

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`
- Test: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineMultiBoardTests.swift`

**Interfaces:**
- Consumes: `FizzyBoardPairingStore` (Tasks 1-2), `FizzyBoardPairing`.
- Produces: engine now takes `pairingStore: FizzyBoardPairingStore` at init (replacing `mapping: FizzyBoardMapping`); public methods become `func sync(localBoardID: UUID) async throws -> FizzySyncResult` and `func syncFirst(localBoardID: UUID, mode: FirstSyncMode) async throws -> FizzySyncResult`.

The internal `steadyStateSync(localBoard:fizzyBoardID:)` and `syncFirst{PushLocal,ReplaceLocal,Merge}(localBoard:fizzyBoardID:)` are unchanged — only the public guards and the `lastSync` write change.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Services/Fizzy/FizzySyncEngineMultiBoardTests.swift`. This drives a two-pairing store and asserts a sync for board A only touches board A's fizzy id (via `MockURLProtocol` recording requested paths). Follow the existing `FizzySyncEngineTests` setup conventions in that folder for `MockURLProtocol`, `FizzyAuthState`, and the in-memory CoreData context; reuse its `makeEngine`-style helper but inject a `FizzyBoardPairingStore` with two rows.

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncEngine multi-board routing", .serialized)
@MainActor
struct FizzySyncEngineMultiBoardTests {

    @Test("sync(localBoardID:) returns empty when the board is not paired")
    func unpairedBoardIsNoOp() async throws {
        let h = try MultiBoardHarness()
        let result = try await h.engine.sync(localBoardID: UUID())   // never paired
        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(h.requestedPaths.isEmpty)                            // no HTTP at all
    }

    @Test("sync(localBoardID:) routes to that board's fizzy id only")
    func routesToPairedFizzyBoard() async throws {
        let h = try MultiBoardHarness()
        let (boardA, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        _ = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")

        _ = try await h.engine.sync(localBoardID: boardA.id!)

        // Every column/card pull path for this cycle must reference fz-A, never fz-B.
        #expect(h.requestedPaths.contains { $0.contains("fz-A") })
        #expect(h.requestedPaths.allSatisfy { !$0.contains("fz-B") })
    }

    @Test("successful sync records lastSyncAt on that board's row")
    func recordsLastSync() async throws {
        let h = try MultiBoardHarness()
        let (boardA, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        #expect(h.pairingStore.pairing(forLocal: boardA.id!)?.lastSyncAt == nil)
        _ = try await h.engine.sync(localBoardID: boardA.id!)
        #expect(h.pairingStore.pairing(forLocal: boardA.id!)?.lastSyncAt != nil)
    }
}
```

> **Implementer note:** `MultiBoardHarness` is a small test helper local to this file. Build it by copying the in-memory-context + `MockURLProtocol` + auth-state wiring from the existing single-board engine tests in `FenixKanbanTests/Services/Fizzy/` (do NOT invent a new HTTP mock). It must expose: `engine: FizzySyncEngine`, `pairingStore: FizzyBoardPairingStore`, `requestedPaths: [String]` (recorded by the mock protocol), and `seedPairedBoard(name:fizzyBoardID:) -> (Board, FizzyBoardPairing)` which inserts a local `Board` + `upsert`s a pairing and stubs an empty-but-valid fizzy board/column/card response set for that fizzy id. If the existing tests expose a reusable harness, extend it instead of duplicating.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzySyncEngineMultiBoardTests`
Expected: FAIL to compile — `sync(localBoardID:)` and the `pairingStore` init param don't exist yet.

- [ ] **Step 3: Write the implementation**

In `FizzySyncEngine.swift`:

1. Replace the stored property and init param:

```swift
    // was: private let mapping: FizzyBoardMapping
    private let pairingStore: FizzyBoardPairingStore
```

In `init(...)`, replace the `mapping: FizzyBoardMapping` parameter and assignment with:

```swift
        pairingStore: FizzyBoardPairingStore,
```
```swift
        self.pairingStore = pairingStore
```

2. Replace the public `syncFirst(mode:)` guard:

```swift
    func syncFirst(localBoardID: UUID, mode: FirstSyncMode) async throws -> FizzySyncResult {
        guard !isSyncing else { return FizzySyncResult() }
        isSyncing = true
        defer { isSyncing = false }
        guard authState.isConfigured,
              let pairing = pairingStore.pairing(forLocal: localBoardID),
              let localBoard = fetchBoard(by: pairing.localBoardID)
        else {
            return FizzySyncResult()
        }

        switch mode {
        case .pushLocalToFizzy:
            return try await syncFirstPushLocal(localBoard: localBoard, fizzyBoardID: pairing.fizzyBoardID)
        case .replaceLocalWithFizzy:
            return try await syncFirstReplaceLocal(localBoard: localBoard, fizzyBoardID: pairing.fizzyBoardID)
        case .mergeIfNoConflicts:
            return try await syncFirstMerge(localBoard: localBoard, fizzyBoardID: pairing.fizzyBoardID)
        }
    }
```

3. Replace the public `sync()` guard:

```swift
    func sync(localBoardID: UUID) async throws -> FizzySyncResult {
        guard !isSyncing else { return FizzySyncResult() }
        isSyncing = true
        defer { isSyncing = false }
        guard authState.isConfigured,
              let pairing = pairingStore.pairing(forLocal: localBoardID),
              let localBoard = fetchBoard(by: pairing.localBoardID)
        else {
            return FizzySyncResult()
        }
        do {
            let result = try await steadyStateSync(localBoard: localBoard, fizzyBoardID: pairing.fizzyBoardID)
            pairingStore.setLastSync(localBoardID: localBoardID, .now)
            return result
        } catch FizzyError.unauthorized {
            authState.clear()
            throw FizzyError.unauthorized
        }
    }
```

> If the current `steadyStateSync` writes `mapping.setLastSync(.now)` internally, remove that line — `lastSync` is now written by `sync(localBoardID:)` above after a successful cycle.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzySyncEngineMultiBoardTests`
Expected: PASS (3 tests). The build will still fail elsewhere (provider/app/existing engine tests reference the old signatures) — that's expected and fixed in Tasks 4-6. Run this `-only-testing` target; if the whole-suite build is required to link, proceed to Task 4 before a full build.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift FenixKanbanTests/Services/Fizzy/FizzySyncEngineMultiBoardTests.swift
git commit -m "feat(#18): route FizzySyncEngine guards by localBoardID"
```

---

### Task 4: `FizzySyncProvider` per-board routing + pairing CRUD

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift`
- Test: `FenixKanbanTests/Features/Sync/FizzySyncProviderMultiBoardTests.swift`

**Interfaces:**
- Consumes: `FizzyBoardPairingStore` (Tasks 1-2), `FizzySyncEngine.sync(localBoardID:)` (Task 3).
- Produces on `FizzySyncProvider`:
  - init now takes `pairingStore: FizzyBoardPairingStore` (replacing `mapping: FizzyBoardMapping`).
  - `var currentBoardID: UUID?` (set by the UI; the scheduler reads it — Task 5).
  - `func makeEngine(for localBoardID: UUID) -> FizzySyncEngine?` (the existing `makeEngine()` is removed; callers pass a board).
  - `func pair(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?)`, `func unpair(localBoardID: UUID)`, `func setSyncEnabled(localBoardID: UUID, _ enabled: Bool)`.
  - `var pairingStoreRef: FizzyBoardPairingStore` (exposed for the future browser UI, replacing `mappingRef`).
  - `isPaired` → "auth configured AND at least one pairing exists".
  - `sync(boardId:remoteProjectId:)` routes to `engine.sync(localBoardID: boardId)`.
  - `lastSyncDate(for:)` → that board's row.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Features/Sync/FizzySyncProviderMultiBoardTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzySyncProvider multi-board")
@MainActor
struct FizzySyncProviderMultiBoardTests {

    private func makeProvider() -> (FizzySyncProvider, FizzyBoardPairingStore) {
        let store = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "prov-\(UUID()).json")
        )
        let provider = FizzySyncProvider(
            authState: FizzyAuthState(defaults: UserDefaults(suiteName: "prov-\(UUID())")!),
            pairingStore: store,
            persistence: PersistenceController(inMemory: true)
        )
        return (provider, store)
    }

    @Test("isPaired is false with no pairings even when authed-shaped")
    func isPairedRequiresAPairing() {
        let (provider, _) = makeProvider()
        #expect(provider.isPaired == false)
    }

    @Test("pair() and unpair() mutate the store")
    func pairUnpair() {
        let (provider, store) = makeProvider()
        let a = UUID()
        provider.pair(localBoardID: a, fizzyBoardID: "fz-A", fizzyBoardName: "A")
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fz-A")
        provider.unpair(localBoardID: a)
        #expect(store.pairing(forLocal: a) == nil)
    }

    @Test("lastSyncDate(for:) reads that board's row")
    func lastSyncPerBoard() {
        let (provider, store) = makeProvider()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fz-A",
                                       lastSyncAt: Date(timeIntervalSince1970: 10)))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fz-B"))
        #expect(provider.lastSyncDate(for: a) == Date(timeIntervalSince1970: 10))
        #expect(provider.lastSyncDate(for: b) == nil)
    }
}
```

> **Implementer note:** Confirm `FizzyAuthState(defaults:)` and `PersistenceController(inMemory:)` initializers exist with these labels by checking the existing provider/auth tests; if the labels differ, match the repo's actual signatures. Do not change production initializers to fit the test — adapt the test to the real API.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzySyncProviderMultiBoardTests`
Expected: FAIL to compile — `pairingStore:` init param and `pair`/`unpair` undefined.

- [ ] **Step 3: Write the implementation**

In `FizzySyncProvider.swift`:

1. Swap the stored property + init param `mapping: FizzyBoardMapping` → `pairingStore: FizzyBoardPairingStore` (property, init label, assignment). Add:

```swift
    /// The board currently visible in the UI. The scheduler syncs this board
    /// first each round (Task 5). Set by `BoardView` on appear.
    var currentBoardID: UUID?
```

2. Replace `makeEngine()` with a per-board variant:

```swift
    func makeEngine(for localBoardID: UUID) -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            pairingStore: pairingStore,
            context: persistence.viewContext,
            pairingStore cardStore note: // (keep the existing card pairingStore + conflictStore args; see below)
        )
    }
```

> The engine init also takes the card `pairingStore` and `conflictStore` — keep passing those exactly as the current `makeEngine()` does. The only change is adding the board `pairingStore:` argument and removing `mapping:`. Use distinct argument labels as defined in Task 3's engine init (board `pairingStore:`) and the existing card-pairing label.

3. Update `sync(boardId:remoteProjectId:)`:

```swift
    func sync(boardId: UUID, remoteProjectId: String) async throws -> SyncResult {
        guard let engine = makeEngine(for: boardId) else {
            throw FizzyError.requiresInteractiveAuth
        }
        let result = try await engine.sync(localBoardID: boardId)
        WidgetCenter.shared.reloadAllTimelines()
        return SyncResult(
            itemsCreated: result.itemsCreated,
            itemsUpdated: result.itemsUpdated,
            itemsDeleted: result.itemsDeleted,
            errors: result.errors,
            syncDate: .now
        )
    }
```

4. Update accessors and pairing CRUD:

```swift
    func lastSyncDate(for boardId: UUID) -> Date? {
        pairingStore.pairing(forLocal: boardId)?.lastSyncAt
    }

    var isPaired: Bool {
        authState.isConfigured && !pairingStore.isEmpty
    }

    func pair(localBoardID: UUID, fizzyBoardID: String, fizzyBoardName: String?) {
        pairingStore.upsert(FizzyBoardPairing(
            localBoardID: localBoardID,
            fizzyBoardID: fizzyBoardID,
            fizzyBoardName: fizzyBoardName
        ))
    }

    func unpair(localBoardID: UUID) {
        pairingStore.remove(localBoardID: localBoardID)   // never touches Card data
    }

    func setSyncEnabled(localBoardID: UUID, _ enabled: Bool) {
        pairingStore.setSyncEnabled(localBoardID: localBoardID, enabled)
    }

    var pairingStoreRef: FizzyBoardPairingStore { pairingStore }
```

5. Update `signOut()` and `changePairing()` to use the store: `signOut()` calls `authState.clear()` then `pairingStore.clearAll()`. Remove `mappingRef` and the old `changePairing()`/`makeEngine()` if no longer referenced (the single-pair UI is migrated in Task 6).

6. `triggerSync(activityState:)` and `triggerSync()` are rewritten in Task 5 (multi-board loop) — leave them compiling for now by routing through `currentBoardID` if present, else the first pairing; Task 5 finalizes the loop.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzySyncProviderMultiBoardTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift FenixKanbanTests/Features/Sync/FizzySyncProviderMultiBoardTests.swift
git commit -m "feat(#18): per-board routing + pairing CRUD on FizzySyncProvider"
```

---

### Task 5: Serial round-robin multi-board scheduler

**Files:**
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift` (`triggerSync(activityState:)` / `triggerSync()`)
- Test: `FenixKanbanTests/Features/Sync/FizzyMultiBoardSchedulerTests.swift`

**Interfaces:**
- Consumes: `FizzySyncProvider.currentBoardID`, `pairingStore.all()`, `engine.sync(localBoardID:)`.
- Produces: `triggerSync(activityState:)` iterates `syncEnabled` pairings **serial**, **frontmost (`currentBoardID`) first**, then the rest in stored order. Each board synced via its own engine instance, one at a time.

- [ ] **Step 1: Write the failing test**

Create `FenixKanbanTests/Features/Sync/FizzyMultiBoardSchedulerTests.swift`. Assert ordering by recording the sequence of `localBoardID`s the provider drives. The cleanest seam is to record requested fizzy ids in order via `MockURLProtocol` and map them back, OR expose a test-only `syncOrder: [UUID]` the loop appends to. Prefer reusing the engine harness from Task 3.

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("Fizzy multi-board scheduler order", .serialized)
@MainActor
struct FizzyMultiBoardSchedulerTests {

    @Test("frontmost board syncs first, then the rest in stored order")
    func frontmostFirst() async throws {
        let h = try MultiBoardHarness()                       // from Task 3, extended
        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")
        let (c, _) = h.seedPairedBoard(name: "C", fizzyBoardID: "fz-C")

        h.provider.currentBoardID = b.id!                     // B is frontmost
        await h.provider.triggerSync(activityState: SyncActivityState())

        #expect(h.syncedBoardOrder == [b.id!, a.id!, c.id!])  // B first, then stored order
    }

    @Test("disabled boards are skipped")
    func skipsDisabled() async throws {
        let h = try MultiBoardHarness()
        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")
        h.pairingStore.setSyncEnabled(localBoardID: a.id!, false)

        await h.provider.triggerSync(activityState: SyncActivityState())
        #expect(h.syncedBoardOrder == [b.id!])
    }
}
```

> **Implementer note:** Extend `MultiBoardHarness` (Task 3) to also expose `provider: FizzySyncProvider` wired to the same `pairingStore` + auth + in-memory persistence, and `syncedBoardOrder: [UUID]` capturing the order boards were synced. Capture order by mapping the `MockURLProtocol`-recorded fizzy ids back to local board ids (each board's first request marks its turn). Do NOT add production-only test hooks if the mock recording suffices.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyMultiBoardSchedulerTests`
Expected: FAIL — current `triggerSync` syncs at most one board / wrong order.

- [ ] **Step 3: Write the implementation**

Replace `triggerSync(activityState:)` and `triggerSync()` in `FizzySyncProvider`:

```swift
    /// Serial round-robin sync of every `syncEnabled` pairing. The frontmost
    /// board (`currentBoardID`) syncs first, then the rest in stored order.
    /// One engine at a time — preserves the engine's reentrancy guard.
    private func orderedBoardsToSync() -> [UUID] {
        let enabled = pairingStore.all().filter(\.syncEnabled).map(\.localBoardID)
        guard let front = currentBoardID, enabled.contains(front) else { return enabled }
        return [front] + enabled.filter { $0 != front }
    }

    func triggerSync(activityState: SyncActivityState) async {
        let order = orderedBoardsToSync()
        guard !order.isEmpty else { return }
        var aggregate = FizzySyncResult()
        var firstError: String?
        for boardID in order {
            guard let engine = makeEngine(for: boardID) else { continue }
            do {
                let result = try await engine.sync(localBoardID: boardID)
                aggregate.merge(result)                       // see note
                if firstError == nil, let e = result.errors.first { firstError = e }
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        activityState.update(from: aggregate, conflictStore: conflictStore)
        if let firstError { activityState.markError(firstError) }
        activityState.lastSyncAt = .now
        await retryPendingComments()
        await retryPendingSteps()
    }

    func triggerSync() async {
        for boardID in orderedBoardsToSync() {
            guard let engine = makeEngine(for: boardID) else { continue }
            _ = try? await engine.sync(localBoardID: boardID)
        }
        await retryPendingComments()
        await retryPendingSteps()
    }
```

> **`FizzySyncResult.merge`:** if `FizzySyncResult` has no `merge`, add a small mutating `merge(_:)` that sums `itemsCreated/itemsUpdated/itemsDeleted` and appends `errors`. Put it next to the struct definition. If an equivalent aggregation already exists, use it instead.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests/FizzyMultiBoardSchedulerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift FenixKanbanTests/Features/Sync/FizzyMultiBoardSchedulerTests.swift FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift
git commit -m "feat(#18): serial round-robin multi-board scheduler"
```

---

### Task 6: App wiring + retire `FizzyBoardMapping`, keep single-pair UI on row 1

**Files:**
- Modify: `FenixKanban/FenixKanbanApp.swift:66-70` (DI wiring + run migration)
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift`, `FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift` (drive row 1 of the store)
- Delete: `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift`
- Modify: `FenixKanban/Features/Board/BoardView.swift` (set `provider.currentBoardID` on appear)
- Test: full suite green

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: a building app whose existing single-pair flow operates on `pairingStore` row 1, with `currentBoardID` reported.

- [ ] **Step 1: Update app DI wiring + migration**

In `FenixKanbanApp.swift`, replace the provider construction:

```swift
        let fizzyBoardPairingStore = FizzyBoardPairingStore()
        fizzyBoardPairingStore.migrateLegacyMappingIfNeeded()   // silent, one-time
        let fizzyProvider = FizzySyncProvider(
            authState: FizzyAuthState(),
            pairingStore: fizzyBoardPairingStore,
            persistence: PersistenceController.shared
        )
        PluginRegistry.shared.register(fizzyProvider)
```

- [ ] **Step 2: Migrate the single-pair UI to row 1**

In `FizzyAuthStatusView` and `FizzyAuthPairView`, replace every `mappingRef` / `FizzyBoardMapping` use:
- Reads of the current pairing → `provider.pairingStoreRef.all().first`.
- "Pair this board" → `provider.pair(localBoardID:fizzyBoardID:fizzyBoardName:)`.
- "Change pairing" / sign-out-of-board → `provider.unpair(localBoardID:)` on that row's id (or `pairingStoreRef.clearAll()` for the single-pair "unpair" button).
- `syncNow()` → `provider.sync(boardId: row.localBoardID, remoteProjectId: row.fizzyBoardID)`.
- `lastSyncAt` display → `provider.lastSyncDate(for: row.localBoardID)`.

Show the code you change in each view; keep the visual layout identical — this is a backing-store swap, not a redesign.

- [ ] **Step 3: Report `currentBoardID`**

In `BoardView`, where the visible board is known, set it on the provider:

```swift
    .onAppear {
        (PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider)?
            .currentBoardID = board.id
    }
```

> Use the repo's actual accessor for the registered provider (match how `SyncSettingsView` reaches `FizzySyncProvider`); if the provider is injected via environment/`AppDependencyManager`, use that path instead of `PluginRegistry.shared.provider(named:)`.

- [ ] **Step 4: Delete `FizzyBoardMapping.swift` and fix remaining references**

```bash
git rm FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift
```
Then build; fix every remaining compile error referencing `FizzyBoardMapping` (old engine/provider tests must be updated to the new `pairingStore:` init + `sync(localBoardID:)` / `syncFirst(localBoardID:mode:)` signatures). Update those existing tests in place — do not delete coverage.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FenixKanbanTests`
Expected: `** TEST SUCCEEDED **`, 0 failures. Then macOS build:
Run: `xcodebuild build -scheme FenixKanban -destination 'generic/platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift FenixKanban/Features/Sync/Fizzy/FizzyAuthStatusView.swift FenixKanban/Features/Sync/Fizzy/FizzyAuthPairView.swift FenixKanban/Features/Board/BoardView.swift
git add -u FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift   # stage the deletion
# plus any updated existing test files, staged by explicit path
git commit -m "feat(#18): wire FizzyBoardPairingStore, retire FizzyBoardMapping"
```

---

## Self-Review

**Spec coverage:**
- Device-local pairing store → Task 1. ✅
- Silent migration to row 1 → Task 2. ✅
- Engine per-board guards → Task 3. ✅
- Provider per-board routing + pairing CRUD → Task 4. ✅
- Serial round-robin scheduler (frontmost first) → Task 5. ✅
- App wiring + retire singleton + keep single-pair UI working → Task 6. ✅
- Unpair never touches Card data → Task 4 (`unpair` → `remove`) + asserted in Task 4 test intent and Task 6 UI mapping. ✅
- Browser UI / create-pull-link flows → **out of scope for 7a** (Phases 7b/7c, separate plans).

**Placeholder scan:** No TBD/TODO. The two implementer notes (`MultiBoardHarness`, provider accessor path) point at concrete existing patterns to copy rather than leaving logic unspecified.

**Type consistency:** `FizzyBoardPairing` fields and store method names are identical across Tasks 1-6. Engine init uses board `pairingStore:` (Task 3) and the provider passes it (Task 4). `sync(localBoardID:)` / `syncFirst(localBoardID:mode:)` consistent Tasks 3-5. `currentBoardID` defined in Task 4, consumed in Tasks 5-6.

## Phase staging

7a (this plan) delivers a working, fully-tested headless multi-board core behind the unchanged single-pair UI. **7b (unified board browser)** and **7c (create/pull/link flows)** get their own plans, written once 7a's concrete interfaces (`pairingStoreRef`, `pair/unpair/setSyncEnabled`, `currentBoardID`, `FizzyBoardPairing`) are merged — so their tasks reference real, merged signatures.
