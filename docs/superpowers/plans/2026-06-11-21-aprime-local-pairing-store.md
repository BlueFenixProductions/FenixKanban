# Issue #21 A′ — Local-Only Card Pairing Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Fizzy card-pairing state (`fizzyID`/`fizzyNumber`/`fizzyUpdatedAt`) out of CloudKit-synced Core Data attributes into a device-local JSON-backed store keyed by card UUID, killing the duplication loop of issue #21.

**Architecture:** A new `FizzyCardPairingStore` (file-backed, atomic writes) becomes the single authority on which local card owns which remote card. The existing CloudKit attributes `fizzyID`/`fizzyNumber` are demoted to a self-healing **hint channel**: written at pairing time and re-healed every sync (for the UI's per-card routes and multi-device/reinstall bootstrap), but never read for sync decisions except to seed a cold store. The adoption-marker mechanism (#14) is deleted — live forensics (2026-06-10) proved Fizzy's ActionText sanitizer strips HTML comments on write, so markers never existed on real remote cards. Reworked tests use **sanitizer-faithful stateful mocks** (strip HTML comments on every write) so no test can certify a fictional server again.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`@Suite`), Core Data + NSPersistentCloudKitContainer (model stays at v8 — no migration), MockURLProtocol test harnesses.

**Context (captain's ruling, issue #21 comment 2026-06-10):**
- Option B (persistent markers, commits `e7d64d2`/`83842bb`/`ad4586f`) is harmless but ineffective — server strips markers. Rework its code and tests as part of A′.
- Pairing must live where neither CloudKit nor the Fizzy server can touch it.
- Multi-device bootstrap needs a replacement hint channel → the demoted attributes ARE the hint channel (no model change, no migration risk).
- Real-server round-trip lesson → encoded as sanitizer-faithful mocks + a manual live-UAT checklist (Task 8).
- Syncing is stood down operationally until this lands. Fizzy board holds ~96 cards (3 duplicate generations); purge is a post-landing ops task **requiring the captain**.

**Worktree/branch:** `claude/nervous-wing-f6a635` (based on `develop` @ `ad4586f`). Merge back to `develop` at the end.

**Test command setup (run once per session):**
```bash
# Pinned simulator (two iPhone 17 sims exist; pin by UDID — see .remember note).
# Resolve: xcrun simctl list devices | grep -A3 "iPhone 17"  → UDID starting 1CCA4B1C
export FK_SIM=1CCA4B1C-XXXX-...   # full UDID
xcrun simctl boot "$FK_SIM" 2>/dev/null; xcrun simctl bootstatus "$FK_SIM"
# Full suite:
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination "platform=iOS Simulator,id=$FK_SIM" test
# Single suite:
#   ... test -only-testing:FenixKanbanTests/<SuiteTypeName>
# macOS build check (no test target on macOS):
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build
```

**Non-goals (file as follow-ups in Task 8, do not implement):**
- Removing `fizzyID`/`fizzyNumber`/`fizzyUpdatedAt`/`fizzyEtag` from the Core Data model (v9) — transition-era hint channel still needs them.
- Purging the duplicate cards on the live fizzy board (ops, captain present).
- Moving `Column.fizzyColumnID` (column pairing) to the store — columns re-pair deterministically by normalized name; not part of the #21 duplication loop.
- UI changes — `CardDetailViewModel`/`BoardViewModel`/`FizzyAuthStatusView` keep reading the hint attributes; hints heal every sync.

---

### Task 1: `FizzyCardPairingStore` — the device-local pairing store

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyCardPairingStore.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyCardPairingStoreTests.swift`

The store is pure Foundation (no Core Data, no MockURLProtocol) — tests need no serialization traits.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyCardPairingStore (issue #21 A′)")
struct FizzyCardPairingStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-pairing-tests-\(UUID().uuidString)")
            .appendingPathComponent("FizzyCardPairings.json")
    }

    @Test("set/get/remove round-trip in memory")
    func roundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FizzyCardPairingStore(fileURL: url)
        let id = UUID()
        #expect(store.isEmpty)
        #expect(store.pairing(for: id) == nil)

        let pairing = FizzyCardPairing(fizzyID: "fz1", fizzyNumber: 7, fizzyUpdatedAt: Date(timeIntervalSince1970: 1_000_000))
        store.setPairing(pairing, for: id)
        #expect(store.pairing(for: id) == pairing)
        #expect(store.count == 1)
        #expect(!store.isEmpty)

        store.removePairing(for: id)
        #expect(store.pairing(for: id) == nil)
        #expect(store.isEmpty)
    }

    @Test("pairings persist across instances sharing a file URL")
    func persistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        // Sub-second component on purpose: LWW comparisons need exact Date
        // fidelity through the JSON round-trip.
        let stamp = Date(timeIntervalSinceReferenceDate: 768_000_000.123456)
        FizzyCardPairingStore(fileURL: url)
            .setPairing(FizzyCardPairing(fizzyID: "fzA", fizzyNumber: 21, fizzyUpdatedAt: stamp), for: id)

        let reloaded = FizzyCardPairingStore(fileURL: url)
        let pairing = reloaded.pairing(for: id)
        #expect(pairing?.fizzyID == "fzA")
        #expect(pairing?.fizzyNumber == 21)
        #expect(pairing?.fizzyUpdatedAt == stamp)
    }

    @Test("missing or corrupt file loads as an empty store")
    func corruptFileLoadsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json{{".utf8).write(to: url)
        let store = FizzyCardPairingStore(fileURL: url)
        #expect(store.isEmpty)
        // And it recovers: the next write succeeds.
        let id = UUID()
        store.setPairing(FizzyCardPairing(fizzyID: "fzB", fizzyNumber: 1, fizzyUpdatedAt: .now), for: id)
        #expect(FizzyCardPairingStore(fileURL: url).pairing(for: id)?.fizzyID == "fzB")
    }

    @Test("allPairings snapshots every entry; removeAll wipes the file")
    func allPairingsAndRemoveAll() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FizzyCardPairingStore(fileURL: url)
        let a = UUID(), b = UUID()
        store.setPairing(FizzyCardPairing(fizzyID: "fzA", fizzyNumber: 1, fizzyUpdatedAt: .now), for: a)
        store.setPairing(FizzyCardPairing(fizzyID: "fzB", fizzyNumber: 2, fizzyUpdatedAt: .now), for: b)
        let all = store.allPairings()
        #expect(Set(all.keys) == [a, b])

        store.removeAll()
        #expect(store.isEmpty)
        #expect(FizzyCardPairingStore(fileURL: url).isEmpty, "removeAll persists")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:FenixKanbanTests/FizzyCardPairingStoreTests`
Expected: BUILD FAILURE — `cannot find 'FizzyCardPairingStore' in scope` (fails for the right reason: type doesn't exist).

- [ ] **Step 3: Implement the store**

```swift
import Foundation
import os

/// One local card's pairing with its Fizzy twin.
struct FizzyCardPairing: Codable, Equatable {
    var fizzyID: String
    var fizzyNumber: Int64
    var fizzyUpdatedAt: Date
}

/// Device-local card-pairing store, keyed by local card UUID (issue #21 A′).
///
/// Pairing is device-truth, not document-truth: which remote card a local
/// card maps to is a fact about THIS device's sync session. It must live
/// where neither CloudKit (whose imports clobber freshly written attribute
/// values with stale record versions — issue #21) nor the Fizzy server
/// (whose ActionText sanitizer strips embedded adoption markers on write)
/// can touch it.
///
/// Backed by a JSON sidecar in Application Support, written atomically on
/// every mutation. Loaded once at init; a missing or unreadable file is an
/// empty store — `FizzySyncEngine.seedPairingStoreIfCold` re-seeds from the
/// CloudKit hint attributes and the orphan-claim heuristic heals the rest.
final class FizzyCardPairingStore: @unchecked Sendable {

    /// Process-wide instance backed by the production sidecar file.
    static let shared = FizzyCardPairingStore()

    let fileURL: URL
    private let lock = NSLock()
    private var pairings: [String: FizzyCardPairing]
    private static let logger = Logger(subsystem: "com.bluefenixproductions.FenixKanban", category: "FizzyCardPairingStore")

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FenixKanban", directoryHint: .isDirectory)
            .appending(path: "FizzyCardPairings.json")
    }

    init(fileURL: URL = FizzyCardPairingStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: FizzyCardPairing].self, from: data) {
            pairings = decoded
        } else {
            pairings = [:]
        }
    }

    var isEmpty: Bool { lock.withLock { pairings.isEmpty } }
    var count: Int { lock.withLock { pairings.count } }

    func pairing(for cardID: UUID) -> FizzyCardPairing? {
        lock.withLock { pairings[cardID.uuidString] }
    }

    func setPairing(_ pairing: FizzyCardPairing, for cardID: UUID) {
        lock.withLock {
            pairings[cardID.uuidString] = pairing
            persistLocked()
        }
    }

    func removePairing(for cardID: UUID) {
        lock.withLock {
            guard pairings.removeValue(forKey: cardID.uuidString) != nil else { return }
            persistLocked()
        }
    }

    func removeAll() {
        lock.withLock {
            guard !pairings.isEmpty else { return }
            pairings = [:]
            persistLocked()
        }
    }

    /// Snapshot of every pairing, keyed by card UUID.
    func allPairings() -> [UUID: FizzyCardPairing] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: pairings.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
    }

    /// Must be called with `lock` held. Atomic write. The default Codable
    /// Date representation (timeIntervalSinceReferenceDate as Double) keeps
    /// exact Date fidelity through the round-trip — LWW comparisons depend
    /// on it; do NOT switch to .iso8601 (truncates sub-second precision).
    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(pairings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Degrades to in-memory pairing for this launch; the next
            // sync's cold-store seeding + orphan heuristic recover.
            Self.logger.error("pairing store persist failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild ... test -only-testing:FenixKanbanTests/FizzyCardPairingStoreTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyCardPairingStore.swift FenixKanbanTests/Services/Fizzy/FizzyCardPairingStoreTests.swift
git commit -m "feat(21): FizzyCardPairingStore — device-local pairing sidecar (A′)"
```

Note: the new file must be added to the Xcode project. The project uses folder-synchronized groups (check: if `make generate` exists, run it; otherwise verify the file appears in the build by building). If the build can't see the type, run `make generate` to regenerate the project.

---

### Task 2: Thread the store through engine, repository, provider, and test harnesses

Pure plumbing — no behavior change. The full suite must stay green (387 tests).

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift:17-42` (property + init)
- Modify: `FenixKanban/Core/Repositories/CardRepository.swift:16-21` (property + init)
- Modify: `FenixKanban/Features/Sync/Fizzy/FizzySyncProvider.swift:139-148` (`makeEngine`)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineAdoptionResilienceTests.swift:11-61` (AdoptionHarness)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (its Harness — same pattern)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineBoardIsolationTests.swift` (its harness — same pattern)
- Modify: `FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift` (its harness — same pattern)

- [ ] **Step 1: Engine — add the dependency (explicit, no default: every construction site must choose)**

```swift
    private let client: FizzyClient
    private let authState: FizzyAuthState
    private let mapping: FizzyBoardMapping
    private let context: NSManagedObjectContext
    /// Device-local pairing authority (issue #21 A′). CloudKit-synced
    /// attributes on Card are demoted to a self-healing hint channel.
    private let pairingStore: FizzyCardPairingStore
```

```swift
    init(
        client: FizzyClient,
        authState: FizzyAuthState,
        mapping: FizzyBoardMapping,
        context: NSManagedObjectContext,
        pairingStore: FizzyCardPairingStore
    ) {
        self.client = client
        self.authState = authState
        self.mapping = mapping
        self.context = context
        self.pairingStore = pairingStore
    }
```

Also update the engine's three inline `CardRepository(context: context)` constructions (lines ~210, ~430, ~492) to `CardRepository(context: context, pairingStore: pairingStore)`.

- [ ] **Step 2: CardRepository — add the dependency (defaulted: UI call sites stay untouched)**

```swift
final class CardRepository: CardRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let pairingStore: FizzyCardPairingStore

    init(context: NSManagedObjectContext, pairingStore: FizzyCardPairingStore = .shared) {
        self.context = context
        self.pairingStore = pairingStore
    }
```

(`pairingStore` is unused until Task 6 — that's fine, it's plumbing. If the compiler warns about it being unused, it won't: stored properties don't warn.)

- [ ] **Step 3: FizzySyncProvider.makeEngine — wire the shared store**

```swift
    func makeEngine() -> FizzySyncEngine? {
        guard let client = makeClient() else { return nil }
        return FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext,
            pairingStore: .shared
        )
    }
```

- [ ] **Step 4: Test harnesses — temp-file store per harness instance**

In `AdoptionHarness` (and the analogous harnesses in `FizzySyncEngineTests.swift`, `FizzySyncEngineBoardIsolationTests.swift`, `FirstSyncModeTests.swift`):

```swift
    let pairingStore: FizzyCardPairingStore
    // in init(), before the engine is built:
    pairingStore = FizzyCardPairingStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
    )
    cardRepo = CardRepository(context: persistence.viewContext, pairingStore: pairingStore)
    // engine construction gains:
    engine = FizzySyncEngine(
        client: client, authState: authState, mapping: mapping,
        context: persistence.viewContext, pairingStore: pairingStore
    )
    // in tearDown():
    try? FileManager.default.removeItem(at: pairingStore.fileURL)
```

CRITICAL: every harness must inject a temp store — `.shared` in tests would write to the developer's real Application Support sidecar.

- [ ] **Step 5: Build both platforms + full suite**

Run: full iOS suite + macOS build (commands in header).
Expected: 387 + 4 = 391 tests PASS, zero warnings, macOS `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add -A FenixKanban FenixKanbanTests
git commit -m "refactor(21): thread FizzyCardPairingStore through engine/repo/provider/harnesses"
```

---

### Task 3: Steady-state sync — the store becomes the pairing authority

The core of A′. The engine's steady-state cycle stops reading/writing pairing through Card attributes; the store decides everything. Cold stores seed from attribute hints; hints heal every cycle. The marker-adoption block dies. Reworked tests get **sanitizer-faithful mocks** (HTML comments stripped on every stored write — matching production Fizzy).

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (steadyStateSync ~96-301, reconcilePins ~309-321, applyRemote ~690-714, new helpers)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineAdoptionResilienceTests.swift`

**Test rework map (this task):**

| Old test | Fate |
|---|---|
| `pullAdoptsByMarker` | DELETE — mechanism gone (server strips markers; store makes it unnecessary) |
| `markerWinsOverHeuristic` | DELETE — no markers |
| `adoptionStableWithPersistentMarker` | REWORK → `pairedSteadyStateStaysQuiet` (store-paired, repeated syncs, zero churn) |
| `saveFailureDoesNotDuplicateOnNextSync` | REWORK — store survives context-save failure (stronger guarantee than markers) |
| `cloudKitClobberHealsWithoutDuplicate` | REWORK → `cloudKitClobberCannotUnpair` (sanitizing mock; attributes clobbered; store untouched; hints heal; 4th sync quiet) |
| `clobberedFizzyIDRepairsByNumber` | REWORK → `coldStoreSeedsByNumberHint` (same scenario, now via seeding; asserts store warm after) |
| `saveFailureSurfacesInErrors` | KEEP as-is |
| `postCarriesMarker` | UNTOUCHED here (Task 4 reworks it) |
| `unownedMarkerCreatesCardNormally` | UNTOUCHED here (Task 4 reworks it) |

New tests: `coldStoreSeedsFromAttributeHints`.

- [ ] **Step 1: Add the sanitizer helper to the test file (below `jsonData`)**

```swift
/// Mimics Fizzy's ActionText rich-text sanitizer: HTML comments are
/// stripped ON WRITE (verified against the production DB, 2026-06-10 —
/// issue #21 forensics: 41 marker-POSTed cards, zero retained markers).
/// Every stateful mock MUST pass stored descriptions through this so a
/// write→read round-trip can never certify a fictional server again.
private func sanitizedDescription(_ raw: Any?) -> Any {
    guard let s = raw as? String, !s.isEmpty else { return NSNull() }
    let stripped = s.replacingOccurrences(
        of: #"(?:\n\n)?<!--[\s\S]*?-->"#, with: "", options: .regularExpression
    )
    return stripped.isEmpty ? NSNull() : stripped
}
```

- [ ] **Step 2: Write the failing flagship test — replace `cloudKitClobberHealsWithoutDuplicate` entirely with:**

```swift
    @Test("CloudKit attribute clobber cannot unpair — the store is the authority, hints heal")
    func cloudKitClobberCannotUnpair() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Production shape of issue #21: a CloudKit import clobbers ALL
        // synced pairing attributes to nil/zero after a successful pairing.
        // The server strips adoption markers (sanitizer-faithful mock), the
        // number is zeroed (no re-pair-by-number), and createdAt is
        // backdated 10 minutes (the title±60s heuristic can't claim the
        // remote). Only the local pairing store can prevent a duplicate.
        let remoteCreated = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        card.createdAt = remoteCreated.addingTimeInterval(-600)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        var postCount = 0
        var putCount = 0
        var nextNumber = 20
        var remotesByNumber: [Int: [String: Any]] = [:]
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData(Array(remotesByNumber.values)), .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                nextNumber += 1
                let payload = cardWritePayload(of: req)
                var dict = remoteCardDict(
                    id: "fz-\(nextNumber)", number: nextNumber,
                    title: payload?["title"] as? String ?? "?",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                dict["description"] = sanitizedDescription(payload?["description"])
                remotesByNumber[nextNumber] = dict
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(nextNumber)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let number = Int((p as NSString).lastPathComponent) ?? 0
                guard let stored = remotesByNumber[number] else {
                    Issue.record("GET for unknown card number \(number)")
                    return (Data(), .response(for: req, status: 404))
                }
                return (jsonData(stored), .ok(for: req))
            case ("PUT", let p?) where p.contains("/cards/"):
                putCount += 1
                let number = Int((p as NSString).lastPathComponent) ?? 0
                guard remotesByNumber[number] != nil else {
                    Issue.record("PUT for unknown card number \(number)")
                    return (Data(), .response(for: req, status: 404))
                }
                let payload = cardWritePayload(of: req)
                remotesByNumber[number]?["title"] = payload?["title"] ?? "?"
                remotesByNumber[number]?["description"] = sanitizedDescription(payload?["description"])
                return (jsonData(remotesByNumber[number]!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: the local card pairs via POST — into the pairing store.
        let first = try await h.engine.sync()
        #expect(first.errors.isEmpty)
        #expect(postCount == 1)
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fz-21")
        #expect(card.fizzyID == "fz-21", "hint attributes written at pairing time")

        // Sync 2: steady-state cycle while everything is intact.
        let second = try await h.engine.sync()
        #expect(second.errors.isEmpty)

        // Between syncs: a CloudKit import clobbers ALL hint attributes.
        card.fizzyID = nil
        card.fizzyNumber = 0
        card.fizzyUpdatedAt = nil
        try h.persistence.viewContext.save()

        // Sync 3: the store still owns the pairing — never POST.
        let third = try await h.engine.sync()
        #expect(postCount == 1, "no duplicate POST — the pairing store is CloudKit-proof")
        #expect(third.errors.isEmpty)
        #expect(card.fizzyID == "fz-21", "fizzyID hint healed from the store")
        #expect(card.fizzyNumber == 21, "fizzyNumber hint healed from the store")
        #expect(remotesByNumber.count == 1, "exactly one Hero remotely")
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero locally")

        // Sync 4: hint healing must not have bumped modifiedAt — the next
        // cycle stays completely quiet (no PUT/POST echo).
        let putsBefore = putCount
        let fourth = try await h.engine.sync()
        #expect(fourth.errors.isEmpty)
        #expect(postCount == 1)
        #expect(putCount == putsBefore, "hint healing causes no echo-PUT")
    }
```

- [ ] **Step 3: Run to verify it fails for the right reason**

Run: `xcodebuild ... test -only-testing:FenixKanbanTests/FizzySyncEngineResilienceTests`
Expected: FAIL on `postCount == 1` (actual 2) in sync 3 — the sanitizing mock removed the marker net, the backdated createdAt defeats the heuristic, the zeroed number defeats re-pair-by-number, and the store isn't consulted yet. (Older sibling tests still pass — don't touch them yet.)

- [ ] **Step 4: Commit the RED**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzySyncEngineAdoptionResilienceTests.swift
git commit -m "test(21): clobber cannot unpair under a sanitizer-faithful server (RED, A')"
```

- [ ] **Step 5: Engine — add pairing helpers (new MARK section, replacing the "Adoption marker" section location is fine; marker statics stay until Task 4)**

```swift
    // MARK: - Pairing store access (issue #21 A′)

    /// The store entry for a card, if paired.
    private func pairing(for card: Card) -> FizzyCardPairing? {
        card.id.flatMap { pairingStore.pairing(for: $0) }
    }

    /// Records (or refreshes) a card's pairing in the local store and heals
    /// the CloudKit-synced hint attributes. The store is the authority; the
    /// attributes survive only as a bootstrap hint channel (cold store on a
    /// fresh install / second device) and for the UI's per-card routes.
    private func recordPairing(for card: Card, fizzyID: String, number: Int64, updatedAt: Date) {
        guard let id = card.id else { return }
        pairingStore.setPairing(
            FizzyCardPairing(fizzyID: fizzyID, fizzyNumber: number, fizzyUpdatedAt: updatedAt),
            for: id
        )
        healHints(on: card, fizzyID: fizzyID, number: number)
    }

    /// Re-writes the hint attributes when they drift from the store —
    /// CloudKit imports clobber them with stale record versions; nothing
    /// reads them for sync decisions. Never bumps `modifiedAt`: hint writes
    /// are not content edits and must not trigger LWW echo-pushes.
    private func healHints(on card: Card, fizzyID: String, number: Int64) {
        if card.fizzyID != fizzyID { card.fizzyID = fizzyID }
        if card.fizzyNumber != number { card.fizzyNumber = number }
    }

    /// Seeds the pairing store from the CloudKit-carried hint attributes
    /// when the store is cold (zero entries): upgrade from a pre-A′ build,
    /// fresh reinstall, or a second device that received cards via
    /// CloudKit. A hint with a number but no fizzyID (pre-A′ clobber
    /// residue) resolves through the remote list.
    private func seedPairingStoreIfCold(localCards: [Card], remoteCards: [FizzyCard]) {
        guard pairingStore.isEmpty else { return }
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        let remoteByNumber: [Int64: FizzyCard] = Dictionary(
            remoteCards.map { (Int64($0.number), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for card in localCards {
            guard let id = card.id else { continue }
            if let fizzyID = card.fizzyID {
                let number = card.fizzyNumber != 0
                    ? card.fizzyNumber
                    : remoteByID[fizzyID].map { Int64($0.number) } ?? 0
                pairingStore.setPairing(
                    FizzyCardPairing(
                        fizzyID: fizzyID, fizzyNumber: number,
                        fizzyUpdatedAt: card.fizzyUpdatedAt ?? .distantPast
                    ),
                    for: id
                )
            } else if card.fizzyNumber != 0, let remote = remoteByNumber[card.fizzyNumber] {
                pairingStore.setPairing(
                    FizzyCardPairing(
                        fizzyID: remote.id, fizzyNumber: card.fizzyNumber,
                        fizzyUpdatedAt: card.fizzyUpdatedAt ?? .distantPast
                    ),
                    for: id
                )
            }
        }
    }
```

- [ ] **Step 6: Engine — rewrite the pairing sections of `steadyStateSync`**

Replace lines ~126-175 (the `pairedByFizzyID` build, the re-pair-by-number block, AND the marker-adoption block) with:

```swift
        // Local cards keyed by fizzyID — pairing comes from the device-local
        // store (issue #21 A′), which CloudKit cannot clobber. Seed the
        // store from the legacy hint attributes when cold.
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { col -> [Card] in
            (col.cards as? Set<Card>).map { Array($0) } ?? []
        }
        seedPairingStoreIfCold(localCards: localCards, remoteCards: remoteCards)

        // First-wins on the pathological duplicate-pairing case (two local
        // cards claiming one remote — e.g. a CloudKit duplicate import):
        // the loser stays inert locally rather than crashing or duplicating.
        var pairedByFizzyID: [String: Card] = [:]
        for card in localCards {
            guard let p = pairing(for: card), pairedByFizzyID[p.fizzyID] == nil else { continue }
            pairedByFizzyID[p.fizzyID] = card
        }
```

Then update the remaining pairing touch points in `steadyStateSync`:

1. Orphan-claim loop condition (line ~185): `for card in localCards where pairing(for: card) == nil {`

2. LWW loop (lines ~215-247) becomes:

```swift
        // LWW for paired cards.
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        for (fizzyID, card) in pairedByFizzyID {
            guard let remote = remoteByID[fizzyID], var p = pairing(for: card) else { continue }
            // Backfill the card number — Fizzy addresses per-card routes by
            // `number`, not the opaque `id`. Cards paired before this field
            // existed self-heal here on their next sync.
            if p.fizzyNumber == 0 {
                p.fizzyNumber = Int64(remote.number)
                if let id = card.id { pairingStore.setPairing(p, for: id) }
            }
            // Heal the hint attributes every cycle — CloudKit imports may
            // have clobbered them; the UI reads them for per-card routes.
            healHints(on: card, fizzyID: p.fizzyID, number: p.fizzyNumber)

            let localFizzyTimestamp = p.fizzyUpdatedAt
            let localModified = card.modifiedAt ?? .distantPast
            let remoteTimestamp = remote.lastActiveAt

            if remoteTimestamp > localFizzyTimestamp && localModified <= localFizzyTimestamp {
                // Remote newer, local untouched → pull.
                applyRemote(remote, to: card)
                result.itemsUpdated += 1
            } else if localModified > localFizzyTimestamp {
                // Local edited since last sync → push.
                do {
                    let updated = try await putCard(card, number: p.fizzyNumber)
                    recordPairing(for: card, fizzyID: fizzyID, number: p.fizzyNumber, updatedAt: updated.lastActiveAt)
                    card.modifiedAt = updated.lastActiveAt
                    result.itemsUpdated += 1
                } catch let error as FizzyError {
                    result.errors.append("Push update '\(card.title ?? "(untitled)")': \(error)")
                }
            }
            // else: both equal or remote stale → no-op.
        }
```

3. Soft-delete loop (lines ~249-254):

```swift
        // Soft-delete: paired local cards whose fizzyID is no longer in the
        // remote response were deleted on the server.
        for (fizzyID, card) in pairedByFizzyID where remoteByID[fizzyID] == nil {
            if let id = card.id { pairingStore.removePairing(for: id) }
            context.delete(card)
            result.itemsDeleted += 1
        }
```

4. Push loop (lines ~256-278):

```swift
        // Push: local cards with no pairing → claim a precomputed orphan or
        // POST a new card. The pairing lands in the store the moment the
        // server responds — BEFORE context.save() — so a later save failure
        // or crash cannot lose it and duplicate the card next sync.
        for card in localCards where pairing(for: card) == nil {
            if let orphanID = orphansByLocalID[card.objectID],
               let orphan = remoteByID[orphanID] {
                recordPairing(for: card, fizzyID: orphan.id, number: Int64(orphan.number), updatedAt: orphan.lastActiveAt)
                card.modifiedAt = orphan.lastActiveAt
                result.itemsUpdated += 1
                continue
            }
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
                card.modifiedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }
```

5. `reconcilePins` (line ~314): `guard let fizzyID = pairing(for: card)?.fizzyID else { continue }`

6. `applyRemote` (lines ~690-714) — pairing writes go through the store:

```swift
    private func applyRemote(_ remote: FizzyCard, to card: Card) {
        card.title = remote.title
        // Local copies never contain adoption markers (issue #14).
        card.cardDescription = Self.strippingAdoptionMarker(from: remote.description)
        card.isGolden = remote.golden
        recordPairing(for: card, fizzyID: remote.id, number: Int64(remote.number), updatedAt: remote.lastActiveAt)
        card.modifiedAt = remote.lastActiveAt
        // ... (labels + assignees blocks unchanged)
    }
```

(The `strippingAdoptionMarker` call survives until Task 4.)

7. The save-failure comment above `context.save()` (lines ~289-292) becomes:

```swift
        // A failed save must surface — not throw away the whole result and
        // not pass silently (issue #15). Pairing state persists in the
        // device-local store independently of this save, so a save failure
        // can no longer cause duplicate POSTs on the next sync (issue #21 A′).
```

8. The `sync()` doc comment (line ~70-71): change “`sync()` keys off `Card.fizzyID` and won't pair anything by title” to “`sync()` keys off the device-local pairing store and won't pair anything by title”.

NOTE: the marker-adoption block is deleted, but `seedPairingStoreIfCold` must run AFTER `remoteCards` is fetched (line ~124) — keep the local-cards build below the fetch as shown.

- [ ] **Step 7: Rework the three companion tests in the same file**

a. DELETE `pullAdoptsByMarker` and `markerWinsOverHeuristic` (mechanism gone — the suite-level replacement coverage is `cloudKitClobberCannotUnpair` + `coldStoreSeeds*`).

b. REPLACE `adoptionStableWithPersistentMarker` with:

```swift
    @Test("store-paired card stays quiet across repeated syncs — no churn")
    func pairedSteadyStateStaysQuiet() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        card.modifiedAt = baseline
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzM", fizzyNumber: 9, fizzyUpdatedAt: baseline),
            for: cardUUID
        )

        let remote = remoteCardDict(
            id: "fzM", number: 9, title: "Hero",
            description: "Body", createdAtISO: "2026-01-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _), ("POST", _):
                Issue.record("steady state must not write: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        for _ in 0..<2 {
            let result = try await h.engine.sync()
            #expect(result.errors.isEmpty)
            #expect(result.itemsUpdated == 0)
            #expect(result.itemsCreated == 0)
        }
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }
```

c. REPLACE `saveFailureDoesNotDuplicateOnNextSync` with (same stateful mock skeleton as before, but with `sanitizedDescription(...)` applied in the POST and PUT handlers, exactly as in the clobber test of Step 2):

```swift
    @Test("save failure after POST cannot duplicate — the pairing store persists independently")
    func saveFailureDoesNotDuplicateOnNextSync() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Body"
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        // Stateful sanitizer-faithful mock: POSTed cards join the remote
        // list with HTML comments stripped (as production Fizzy does).
        var postCount = 0
        var storedRemote: [String: Any]?
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let list = storedRemote.map { [$0] } ?? []
                return (jsonData(list), .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let payload = cardWritePayload(of: req)
                var dict = remoteCardDict(
                    id: "fzH", number: 21,
                    title: payload?["title"] as? String ?? "?",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                dict["description"] = sanitizedDescription(payload?["description"])
                storedRemote = dict
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/21"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/21"):
                return (jsonData(storedRemote!), .ok(for: req))
            case ("PUT", let p?) where p.hasSuffix("/cards/21"):
                let payload = cardWritePayload(of: req)
                storedRemote?["description"] = sanitizedDescription(payload?["description"])
                storedRemote?["title"] = payload?["title"] ?? "?"
                return (jsonData(storedRemote!), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        // Sync 1: POST succeeds, but the context save fails (poisoned
        // context) — unsaved attribute changes are lost as if the app died.
        let poison = Card(context: h.persistence.viewContext)
        poison.id = UUID()
        poison.title = nil

        let first = try await h.engine.sync()
        #expect(postCount == 1)
        #expect(first.errors.contains { $0.localizedCaseInsensitiveContains("save") })

        // Simulate process restart: unsaved context changes are gone — but
        // the pairing store already persisted the pairing.
        h.persistence.viewContext.rollback()
        #expect(card.fizzyID == nil, "hint attribute was never saved")
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fzH", "store write survived")

        // Sync 2: no duplicate POST. (The LWW push may PUT — rollback
        // restored a modifiedAt newer than the stored fizzyUpdatedAt; that
        // is correct push-my-edit behavior, not duplication.)
        let second = try await h.engine.sync()
        #expect(postCount == 1, "no second POST — the store prevented the duplicate")
        #expect(second.errors.isEmpty)
        #expect(card.fizzyID == "fzH", "hint healed from the store")
        #expect(card.fizzyNumber == 21)

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1, "exactly one Hero — locally and remotely")
    }
```

d. REPLACE `clobberedFizzyIDRepairsByNumber` with:

```swift
    @Test("cold store seeds from a number-only hint (pre-A′ clobber residue)")
    func coldStoreSeedsByNumberHint() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Pre-A′ data shape: fizzyID clobbered to nil, number survived.
        // Seeding resolves the number against the remote list.
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.fizzyID = nil
        card.fizzyNumber = 7
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)

        let remote = remoteCardDict(
            id: "fz7", number: 7, title: "Hero (renamed remotely)",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        var postCount = 0
        var putPaths: [String] = []
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", let p?):
                putPaths.append(p)
                var updated = remote
                updated["title"] = "Hero"
                return (jsonData(updated), .ok(for: req))
            case ("POST", _):
                postCount += 1
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(postCount == 0, "seeded pairing — never re-POST")
        #expect(h.pairingStore.pairing(for: cardUUID)?.fizzyID == "fz7", "store seeded from the number hint")
        #expect(card.fizzyID == "fz7", "fizzyID hint healed")
        #expect(result.itemsCreated == 0)
        #expect(putPaths == ["/ACCT/cards/7"], "local edit pushed via LWW after seeding")

        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }
```

e. ADD the upgrade-path seeding test:

```swift
    @Test("cold store seeds from full attribute hints — upgrade/reinstall/second device")
    func coldStoreSeedsFromAttributeHints() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Pre-A′ paired card: attributes intact, store empty (first launch
        // of the A′ build — or a second device that got the card via
        // CloudKit). The sync must adopt the hints, not POST a duplicate.
        let baseline = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.fizzyID = "fz9"
        card.fizzyNumber = 9
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        #expect(h.pairingStore.isEmpty)

        let remote = remoteCardDict(
            id: "fz9", number: 9, title: "Hero",
            description: nil, createdAtISO: "2026-05-01T00:00:00Z",
            lastActiveISO: "2026-06-01T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", _), ("POST", _):
                Issue.record("seeded pairing must not write: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        let seeded = h.pairingStore.pairing(for: cardUUID)
        #expect(seeded?.fizzyID == "fz9")
        #expect(seeded?.fizzyNumber == 9)
        #expect(seeded?.fizzyUpdatedAt == baseline)
        let cardCount = try h.persistence.viewContext.count(for: Card.fetchRequest())
        #expect(cardCount == 1)
    }
```

f. Update the two suite titles:
- `"FizzySyncEngine — marker-based adoption (issue #14)"` → `"FizzySyncEngine — pairing store adoption & wire hygiene (issue #21 A′)"`
- `"FizzySyncEngine — sync resilience (issue #15)"` → `"FizzySyncEngine — sync resilience (issues #15/#21 A′)"`

- [ ] **Step 8: Run the full suite**

Run: full iOS suite.
Expected: ALL PASS. (Old tests that arrange pairing by setting attributes directly keep passing — the cold-store seeding adopts their arrangements. `postCarriesMarker` and `unownedMarkerCreatesCardNormally` still pass because postCard/applyRemote marker code is untouched until Task 4.)

- [ ] **Step 9: Commit**

```bash
git add -A FenixKanban FenixKanbanTests
git commit -m "feat(21): pairing store is the sync authority — CloudKit clobber structurally dead (GREEN, A')"
```

---

### Task 4: Clean wire descriptions — delete the marker machinery

The server strips HTML comments anyway; stop sending them. Descriptions now pass through both directions verbatim.

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (delete marker MARK section ~323-358; simplify putCard ~745-766, postCard ~774-799, applyRemote description line; header doc comment)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineAdoptionResilienceTests.swift`

- [ ] **Step 1: Write the failing tests — REPLACE `postCarriesMarker` with:**

```swift
    @Test("POST sends the description verbatim — no marker, wire-clean")
    func postSendsCleanDescription() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let withDesc = h.cardRepo.createCard(in: h.column, title: "WithDesc")
        withDesc.cardDescription = "Hello"
        let noDesc = h.cardRepo.createCard(in: h.column, title: "NoDesc")
        try h.persistence.viewContext.save()

        var postedDescriptionsByTitle: [String: Any] = [:]
        var nextNumber = 40
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let payload = cardWritePayload(of: req)
                if let title = payload?["title"] as? String {
                    postedDescriptionsByTitle[title] = payload?["description"] ?? "(absent)"
                }
                nextNumber += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/\(nextNumber)"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/"):
                let number = Int((p as NSString).lastPathComponent) ?? 0
                let dict = remoteCardDict(
                    id: "fz-\(number)", number: number, title: "x",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(postedDescriptionsByTitle["WithDesc"] as? String == "Hello", "verbatim — no marker suffix")
        #expect(!(postedDescriptionsByTitle["NoDesc"] is String), "nil description stays nil — not a bare marker")
    }
```

- [ ] **Step 2: REPLACE `putReembedsMarkerWithLocalEdit` with:**

```swift
    @Test("LWW push PUT sends the edited description verbatim — no marker")
    func putSendsCleanDescription() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = h.cardRepo.createCard(in: h.column, title: "Hero")
        card.cardDescription = "Edited body"
        card.modifiedAt = baseline.addingTimeInterval(500)
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzP", fizzyNumber: 9, fizzyUpdatedAt: baseline),
            for: cardUUID
        )

        let remote = remoteCardDict(
            id: "fzP", number: 9, title: "Hero",
            description: "Old body",
            createdAtISO: "2026-01-01T00:00:00Z",
            lastActiveISO: ISO8601DateFormatter().string(from: baseline)
        )
        var putDescriptions: [String] = []
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            case ("PUT", let p?) where p.hasSuffix("/cards/9"):
                let payload = cardWritePayload(of: req)
                putDescriptions.append(payload?["description"] as? String ?? "(nil)")
                var updated = remote
                updated["title"] = payload?["title"] ?? "?"
                updated["description"] = sanitizedDescription(payload?["description"])
                return (jsonData(updated), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(putDescriptions == ["Edited body"], "exactly one LWW push PUT, description verbatim")
    }
```

- [ ] **Step 3: REPLACE `unownedMarkerCreatesCardNormally` with the pass-through contract:**

```swift
    @Test("remote descriptions import verbatim — no marker stripping on pull")
    func remoteDescriptionImportsVerbatim() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        // Production remotes never contain markers (the server's sanitizer
        // strips HTML comments on write) — so the engine performs no
        // stripping of its own. What the server returns is what we store.
        let remote = remoteCardDict(
            id: "fzZ", number: 5, title: "Stray",
            description: "Body text",
            createdAtISO: "2026-06-01T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.errors.isEmpty)
        #expect(result.itemsCreated == 1)
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        let stray = try #require(cards.first { $0.title == "Stray" })
        #expect(stray.cardDescription == "Body text")
        #expect(try #require(stray.id) == stray.id) // paired in store:
        #expect(h.pairingStore.pairing(for: try #require(stray.id))?.fizzyID == "fzZ")
    }
```

- [ ] **Step 4: Run to verify failure**

Run: `-only-testing:` both suites in the file.
Expected: `postSendsCleanDescription` FAILS (marker suffix present), `putSendsCleanDescription` FAILS (marker suffix present). `remoteDescriptionImportsVerbatim` PASSES already (stripping a marker-free description is a no-op) — that's fine, it pins the contract.

- [ ] **Step 5: Delete the marker machinery in the engine**

1. Delete the whole `// MARK: - Adoption marker (issue #14)` section (`adoptionMarker(for:)`, `adoptionMarkerPattern`, `adoptionMarkerUUID(in:)`, `strippingAdoptionMarker(from:)`).
2. `putCard` — replace the body's description block:

```swift
    /// PUT an updated local card to the remote. Returns the updated FizzyCard
    /// so we can sync back the server's lastActiveAt.
    private func putCard(_ card: Card, number: Int64) async throws -> FizzyCard {
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: card.cardDescription,
                status: nil,
                tagIds: nil
            )
        )
        return try await client.put(
            "/cards/\(number)",
            body: payload,
            as: FizzyCard.self
        )
    }
```

3. `postCard` — same simplification (description: `card.cardDescription`; delete the marker comment block; keep the tag_ids divergence comment).
4. `applyRemote` — `card.cardDescription = remote.description` (delete the stripping line + its comment).
5. Sweep stale comments: `grep -n "marker\|#14" FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` — rewrite or delete every remaining mention (header comment, steady-state comments). The orphan-heuristic comment (line ~177) keeps its meaning but loses any marker reference.

- [ ] **Step 6: Run the full suite**

Expected: ALL PASS — nothing else referenced the marker statics (verify: `grep -rn "adoptionMarker\|strippingAdoptionMarker" FenixKanban FenixKanbanTests` returns nothing).

- [ ] **Step 7: Commit**

```bash
git add -A FenixKanban FenixKanbanTests
git commit -m "feat(21): delete adoption-marker machinery — wire descriptions verbatim (A')"
```

---

### Task 5: First-sync modes pair through the store

`pushLocalToFizzy`, `replaceLocalWithFizzy`, `mergeIfNoConflicts` still pair via attributes. Move them to the store (replace mode also clears stale pairings when it wipes).

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (`syncFirstPushLocal` ~362-389, `syncFirstReplaceLocal` ~391-439, `syncFirstMerge` ~441-515)
- Modify: `FenixKanbanTests/Services/Fizzy/FirstSyncModeTests.swift` (new tests; existing tests keep passing via seeding)

- [ ] **Step 1: Write the failing tests (append to the existing suite in FirstSyncModeTests.swift, reusing its harness — adapt harness property names to that file's local conventions):**

```swift
    @Test("push mode skips store-paired cards and records new pairings in the store")
    func pushModeUsesStore() async throws {
        let h = /* this file's harness type */()
        defer { h.tearDown() }

        // One card already paired (store only — no attributes), one new.
        let paired = h.cardRepo.createCard(in: h.column, title: "AlreadyPaired")
        let fresh = h.cardRepo.createCard(in: h.column, title: "Fresh")
        try h.persistence.viewContext.save()
        let pairedUUID = try #require(paired.id)
        let freshUUID = try #require(fresh.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzOld", fizzyNumber: 3, fizzyUpdatedAt: .now),
            for: pairedUUID
        )

        var postedTitles: [String] = []
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let payload = cardWritePayload(of: req)
                postedTitles.append(payload?["title"] as? String ?? "?")
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/50"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/50"):
                let dict = remoteCardDict(
                    id: "fzNew", number: 50, title: "Fresh",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .pushLocalToFizzy)

        #expect(result.errors.isEmpty)
        #expect(postedTitles == ["Fresh"], "store-paired card is not re-POSTed")
        #expect(h.pairingStore.pairing(for: freshUUID)?.fizzyID == "fzNew", "new pairing recorded in the store")
        #expect(fresh.fizzyID == "fzNew", "hint attributes written")
    }

    @Test("replace mode clears the wiped cards' pairings and pairs the pulled ones in the store")
    func replaceModeResetsStore() async throws {
        let h = /* this file's harness type */()
        defer { h.tearDown() }

        let old = h.cardRepo.createCard(in: h.column, title: "Old")
        try h.persistence.viewContext.save()
        let oldUUID = try #require(old.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzGone", fizzyNumber: 1, fizzyUpdatedAt: .now),
            for: oldUUID
        )

        let remote = remoteCardDict(
            id: "fzKeep", number: 2, title: "Kept",
            description: nil, createdAtISO: "2026-06-01T00:00:00Z"
        )
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (jsonData([remote]), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .replaceLocalWithFizzy)

        #expect(result.errors.isEmpty)
        #expect(h.pairingStore.pairing(for: oldUUID) == nil, "wiped card's pairing removed")
        let cards = try h.persistence.viewContext.fetch(Card.fetchRequest())
        let kept = try #require(cards.first { $0.title == "Kept" })
        #expect(h.pairingStore.pairing(for: try #require(kept.id))?.fizzyID == "fzKeep")
    }

    @Test("merge mode pairs pushed cards in the store")
    func mergeModeRecordsPairings() async throws {
        let h = /* this file's harness type */()
        defer { h.tearDown() }

        let localOnly = h.cardRepo.createCard(in: h.column, title: "LocalOnly")
        try h.persistence.viewContext.save()
        let localUUID = try #require(localOnly.id)

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (triageColumnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/60"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/60"):
                let dict = remoteCardDict(
                    id: "fzMerge", number: 60, title: "LocalOnly",
                    description: nil, createdAtISO: "2026-06-01T00:00:00Z"
                )
                return (jsonData(dict), .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.syncFirst(mode: .mergeIfNoConflicts)

        #expect(result.errors.isEmpty)
        #expect(h.pairingStore.pairing(for: localUUID)?.fizzyID == "fzMerge")
    }
```

NOTE: `cardWritePayload`/`remoteCardDict`/`jsonData`/`triageColumnsJSON` are `private` to the resilience file — if FirstSyncModeTests lacks equivalents, copy the small helpers into it (private per-file helpers are the established pattern there). Adapt the mock-handler shapes to whatever the existing FirstSyncModeTests mocks look like (e.g. if its push-mode tests don't hit `/my/pins` or `/columns`, mirror that).

- [ ] **Step 2: Run to verify failure**

Expected: `pushModeUsesStore` FAILS (store-paired card has nil `fizzyID` attribute → POSTed; store never written). `replaceModeResetsStore` FAILS (pairing not removed / not recorded). `mergeModeRecordsPairings` FAILS (store not written).

- [ ] **Step 3: Implement — all three modes**

`syncFirstPushLocal`: seed first, then the store alone decides (the hint attribute is consumed by seeding — never checked directly):

```swift
    private func syncFirstPushLocal(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        var result = FizzySyncResult()
        let columns = (localBoard.columns as? Set<Column>) ?? Set<Column>()
        let cards: [Card] = columns.flatMap { column in
            (column.cards as? Set<Card>) ?? Set<Card>()
        }
        // Adopt legacy attribute hints before deciding what to POST (no
        // remote list in push mode — number-only hints can't resolve here).
        seedPairingStoreIfCold(localCards: cards, remoteCards: [])

        for card in cards where pairing(for: card) == nil {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
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

`syncFirstReplaceLocal` — in the wipe loop:

```swift
        for card in localCards {
            if let id = card.id { pairingStore.removePairing(for: id) }
            context.delete(card)
            result.itemsDeleted += 1
        }
```

(The pull half already pairs through the store: `applyRemote` → `recordPairing` since Task 3.)

`syncFirstMerge` — after both fetches, seed; push loop via store:

```swift
        // (right after remoteCards/localCards are built)
        seedPairingStoreIfCold(localCards: localCards, remoteCards: remoteCards)
        ...
        // Push local-only cards (unpaired, not a collision).
        for card in localCards where pairing(for: card) == nil
                                && !remoteTitlesLower.contains(card.title?.lowercased() ?? "") {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                recordPairing(for: card, fizzyID: created.id, number: Int64(created.number), updatedAt: created.lastActiveAt)
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }
```

- [ ] **Step 4: Run the full suite**

Expected: ALL PASS (existing FirstSyncModeTests arrangements seed automatically).

- [ ] **Step 5: Commit**

```bash
git add -A FenixKanban FenixKanbanTests
git commit -m "feat(21): first-sync modes pair through the store (A')"
```

---

### Task 6: Delete path — tombstone number from the store

A clobbered `fizzyNumber` hint at delete time currently means NO tombstone → the deletion never propagates. The store fixes that.

**Files:**
- Modify: `FenixKanban/Core/Persistence/CardTombstone+CoreDataClass.swift:12-18`
- Modify: `FenixKanban/Core/Repositories/CardRepository.swift` (`deleteCard`, ~line 101)
- Test: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineAdoptionResilienceTests.swift` (append to resilience suite — it has the harness with a store-injected `cardRepo`)

- [ ] **Step 1: Write the failing test**

```swift
    @Test("deleteCard tombstones from the store and clears the pairing — even with clobbered hints")
    func deleteUsesStorePairingWhenHintsClobbered() async throws {
        let h = AdoptionHarness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Doomed")
        try h.persistence.viewContext.save()
        let cardUUID = try #require(card.id)
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzD", fizzyNumber: 21, fizzyUpdatedAt: .now),
            for: cardUUID
        )
        // CloudKit clobbered the hint attributes — the store still knows.
        card.fizzyID = nil
        card.fizzyNumber = 0

        h.cardRepo.deleteCard(card)

        let tombstones = try h.persistence.viewContext.fetch(CardTombstone.fetchRequest())
        #expect(tombstones.map(\.fizzyNumber) == [21], "tombstone number comes from the store")
        #expect(h.pairingStore.pairing(for: cardUUID) == nil, "pairing removed on delete")
    }
```

- [ ] **Step 2: Run to verify failure**

Expected: FAIL — `tombstones` is empty (`record(for:)` read the zeroed attribute and returned nil) and the pairing is still present.

- [ ] **Step 3: Implement**

`CardTombstone+CoreDataClass.swift`:

```swift
    /// Records a pending remote deletion for a fizzy-paired card so the next
    /// sync can issue `DELETE /cards/:number`. No-op (returns nil) for cards
    /// that were never paired — Fizzy addresses card routes by `number`, so a
    /// card without one has nothing to delete remotely.
    @discardableResult
    static func record(number: Int64, in context: NSManagedObjectContext) -> CardTombstone? {
        guard number != 0 else { return nil }
        let tombstone = CardTombstone(context: context)
        tombstone.fizzyNumber = number
        tombstone.deletedAt = Date()
        return tombstone
    }
```

`CardRepository.deleteCard`:

```swift
    func deleteCard(_ card: Card) {
        let now = Date()
        card.column?.modifiedAt = now
        card.column?.board?.modifiedAt = now
        // Fizzy-paired cards leave a tombstone so the deletion propagates to
        // the server on the next sync (issue #11). The number comes from the
        // pairing store (the authority — issue #21 A′), falling back to the
        // hint attribute for pre-A′ data whose store was never seeded.
        let number = card.id.flatMap { pairingStore.pairing(for: $0)?.fizzyNumber } ?? card.fizzyNumber
        CardTombstone.record(number: number, in: context)
        if let id = card.id { pairingStore.removePairing(for: id) }
        context.delete(card)
        save()
    }
```

Check for other `CardTombstone.record(for:` callers: `grep -rn "CardTombstone.record" FenixKanban FenixKanbanTests` — update any to the new signature (expected: only CardRepository).

- [ ] **Step 4: Run the full suite**

Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add -A FenixKanban FenixKanbanTests
git commit -m "feat(21): delete path reads the pairing store — tombstones survive hint clobbers (A')"
```

---

### Task 7: Sweep — docs, comments, dual-platform verification

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (header doc, residual comments)
- Modify: `TDD_IMPLEMENTATION_STATUS.md` (append entry #41)

- [ ] **Step 1: Comment sweep**

`grep -rn "marker\|issue #14\|persist.*remotely" FenixKanban/Core --include="*.swift"` — every remaining mention must be accurate post-A′. Update the engine header comment (lines 4-15) to mention the pairing store as a constructor dependency. Update `FizzyAuthStatusView.swift:44`'s vicinity with a one-line comment if none exists: the `fizzyID != nil` predicate counts via hint attributes (healed every sync; cosmetic count).

- [ ] **Step 2: TDD_IMPLEMENTATION_STATUS.md — append entry #41**

Cover: the forensic finding (sanitizer strips markers → Option B void), the A′ design (store = authority, attributes = self-healing hint channel, no model change), the sanitizer-faithful mock policy (no test may certify a write→read round-trip without it), the test rework map, and final counts (tests/suites, both platforms).

- [ ] **Step 3: Full verification**

```bash
xcodebuild ... -destination "platform=iOS Simulator,id=$FK_SIM" test   # full suite
xcodebuild ... -destination 'platform=macOS' build                     # zero warnings
```
Expected: all tests green, both platforms build, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(21): A' sweep — engine header, status log entry #41"
```

---

### Task 8: Ship & operational handoff

- [ ] **Step 1: Merge to develop and push**

```bash
git checkout develop && git merge --no-ff claude/nervous-wing-f6a635 -m "merge: issue #21 A' — local-only pairing store"
git push origin develop
```
(Or keep the branch and open a PR — follow the captain's standing preference; previous waves merged straight to develop.)

- [ ] **Step 2: Issue hygiene (gh CLI)**

- Comment on #21: A′ landed — store design, hint channel, what was deleted, test counts. Note the residual transition-era risk: a second device whose CloudKit copy carries clobbered/nil hints for recently paired cards will seed those cards as unpaired (orphan heuristic is the remaining net).
- Comment on #14: marker mechanism deleted (never worked against production); deterministic adoption is now the pairing store + seeding; propose closing.
- Comment on #15: clobber resilience is now structural; propose closing or re-scoping to the remaining save-failure UX.
- File follow-up: "Remove fizzy pairing attributes from the Core Data model (v9) after the hint-channel transition era" (depends on all devices running A′).
- File follow-up (needs-captain): "Purge duplicate cards on the live fizzy board (~96 → 32, keep-newest-per-title, then soft-delete sweep)" — ops, captain present, after live UAT passes.

- [ ] **Step 3: Manual live-UAT checklist (CAPTAIN — real device, real server; do NOT automate)**

1. Build to Susanoo; confirm the app launches and the gospel board (32 cards) is intact.
2. Re-enable syncing; run 3 steady sync cycles → fizzy card count must not grow; server logs show zero POSTs after cycle 1.
3. Create one test card in FK → sync → verify it appears on fizzy with a **clean description** (no `<!--fk:` anywhere — check the card in the fizzy UI or DB).
4. Edit that card's description in FK → sync → PUT body lands clean; no duplicate.
5. Delete the test card in FK → sync → it's gone on fizzy (tombstone propagation through the store).
6. Reinstall test (cold store + warm CloudKit): delete the app, reinstall, wait for CloudKit restore, re-pair auth + board, run sync → zero duplicates (seeding adopted the hints).
7. Only after all pass: schedule the duplicate purge (follow-up issue).

---

## Self-Review Notes

- **Spec coverage:** captain's three A′ spec additions — (1) real-server round-trip validation → sanitizer-faithful mocks (Tasks 3-5) + live UAT (Task 8); (2) Option B code/test fate → putCard re-embed deleted (Task 4), `cloudKitClobberHealsWithoutDuplicate` reworked against a sanitizing server (Task 3); (3) multi-device bootstrap → hint channel + cold-store seeding (Task 3), residual risk documented in the #21 comment (Task 8). Core requirement (pairing beyond CloudKit/server reach) → Tasks 1-3. Tombstone integrity → Task 6. First-sync integrity → Task 5.
- **Types:** `FizzyCardPairing(fizzyID:fizzyNumber:fizzyUpdatedAt:)`, `FizzyCardPairingStore.pairing(for:)/setPairing(_:for:)/removePairing(for:)/removeAll()/allPairings()/isEmpty/count/fileURL`, engine helpers `pairing(for:)/recordPairing(for:fizzyID:number:updatedAt:)/healHints(on:fizzyID:number:)/seedPairingStoreIfCold(localCards:remoteCards:)`, `CardTombstone.record(number:in:)` — used consistently across tasks.
- **Known acceptable gaps:** stale store entries for cards deleted by CloudKit imports (inert; remote re-import matches current behavior); `Column.fizzyColumnID` stays attribute-based (re-pairs by name); `fizzyUpdatedAt` attribute becomes dead data until v9.
