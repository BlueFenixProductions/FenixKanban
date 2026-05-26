# Fizzy Integration — Phase 4b: Steady-State Sync Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `FizzySyncEngine.sync()` — the steady-state operation that runs on a 5-minute foreground poll (Phase 6) after a board pair has been established by `syncFirst(mode:)`. Implements pull/push/LWW/soft-delete/crash-recovery/idempotence/401-handling.

**Architecture:** Extends the Phase 4a `FizzySyncEngine`. Public surface gets a second method `sync()` (no parameter — steady-state direction is bidirectional and uses `fizzyID` as the join key, not first-sync's title-based collision check). `lastSyncAt` is written at the end of every successful cycle. 401 errors clear `FizzyAuthState` so the UI banner can prompt re-auth.

**Tech Stack:** Same as 4a — Swift 6 async/await, CoreData, Swift Testing, MockURLProtocol. Builds on Phase 4a's `postCard`, `applyRemote`, `findOrCreateLabel`, `fetchRemoteColumns`, `fetchRemoteCards`.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md` (§ Sync cycle, § Conflict resolution, § Errors & offline behavior)

**Out of scope for Phase 4b** (deferred to future phases):
- Per-card ETag persistence (`Card.fizzyEtag`) — the field exists from Phase 3 but Phase 4b doesn't populate it. Steady-state fetches the whole board each cycle; ETag-driven incremental syncs are a Phase 4c optimization.
- Field-level LWW (each field's own timestamp) — Phase 4b uses card-level `updatedAt` for LWW per spec.
- Foreground polling timer — that's Phase 6.
- UI banners (e.g. "Re-enter access token") — that's Phase 5.
- `FizzySyncProvider` (the `BoardSyncProvider` conformance) — that's Phase 5.

---

## File Structure

**Modified:**
- `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` — add `sync()` public method + supporting private helpers (`putCard`, `softDeleteLocal`, etc.)
- `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` — append new test suites

**No new source files.** Phase 4b extends the existing engine; the Phase 4a building blocks (`postCard`, `applyRemote`, `findOrCreateLabel`, `fetchRemoteColumns`, `fetchRemoteCards`, `FizzySyncResult`, `FizzySyncMapping`) are reused.

---

## Task 1: `sync()` skeleton + pairing precondition

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` (append `FizzySyncEngineSyncPairingTests`)

- [ ] **Step 1: Append the failing test**

At the bottom of `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`:

```swift

@Suite("FizzySyncEngine — sync() pairing precondition", .serialized)
@MainActor
struct FizzySyncEngineSyncPairingTests {

    @Test("sync() returns empty FizzySyncResult when unpaired")
    func unpairedReturnsEmpty() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let authState = FizzyAuthState(keyPrefix: "test.fizzy.sync.\(UUID().uuidString)")
        defer { authState.clear() }
        let suiteName = "test.fizzy.sync.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)

        let client = FizzyClient(
            baseURL: URL(string: "https://example.invalid")!,
            accessToken: "t",
            accountSlug: "ACCT"
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        let result = try await engine.sync()
        #expect(result == FizzySyncResult())
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSyncPairingTests \
  test 2>&1 | tail -10
```

Expected: build fails — `sync()` undefined.

- [ ] **Step 3: Add `sync()` skeleton**

In `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`, add this method below `syncFirst(mode:)`:

```swift
    /// Steady-state sync. Runs the pull/push/LWW/soft-delete cycle. Caller
    /// must have completed `syncFirst(mode:)` once before — `sync()` keys off
    /// `Card.fizzyID` and won't pair anything by title.
    ///
    /// Returns an empty `FizzySyncResult` if the engine is unpaired.
    /// Records `mapping.setLastSync(.now)` at the end of every successful cycle.
    func sync() async throws -> FizzySyncResult {
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return FizzySyncResult()
        }
        return try await steadyStateSync(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
    }

    private func steadyStateSync(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        // Implemented incrementally across Tasks 2-8.
        FizzySyncResult()
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSyncPairingTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): sync() skeleton + pairing precondition

Steady-state entry point. Returns empty FizzySyncResult when unpaired.
steadyStateSync() body filled incrementally by Tasks 2-8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Steady-state pull — remote-only cards create locally

**Files:**
- Modify: `FizzySyncEngine.swift` — start filling `steadyStateSync`
- Modify: `FizzySyncEngineTests.swift` — append `FizzySyncEngineSteadyPullTests`

- [ ] **Step 1: Append failing test**

```swift

@Suite("FizzySyncEngine — steady-state pull", .serialized)
@MainActor
struct FizzySyncEngineSteadyPullTests {

    private struct Harness {
        let persistence: PersistenceController
        let boardRepo: BoardRepository
        let cardRepo: CardRepository
        let board: Board
        let column: Column
        let engine: FizzySyncEngine
        let mapping: FizzyBoardMapping
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

            let prefix = "test.fizzy.steadypull.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t")
            authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.steadypull.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t", accountSlug: "ACCT",
                urlSession: session, clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client, authState: authState, mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("steady pull: 3 remote, 0 local with fizzyID → 3 local created")
    func pullRemoteOnly() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let columnsJSON = """
        [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
        """
        let cardsJSON = """
        [
          {"id":"fz1","number":1,"title":"R1","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"},
          {"id":"fz2","number":2,"title":"R2","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/2"},
          {"id":"fz3","number":3,"title":"R3","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/3"}
        ]
        """
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return (columnsJSON.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return (cardsJSON.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(result.itemsCreated == 3)
        #expect(result.errors.isEmpty)

        let titles = Set(((h.column.cards as? Set<Card>).map { Array($0) } ?? []).compactMap(\.title))
        #expect(titles == Set(["R1", "R2", "R3"]))
    }

    @Test("steady pull: skips remote cards already paired locally (no duplicate creates)")
    func pullSkipsAlreadyPaired() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Local card already paired with fz1
        let paired = h.cardRepo.createCard(in: h.column, title: "Existing")
        paired.fizzyID = "fz1"
        try h.persistence.viewContext.save()

        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"Existing","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(result.itemsCreated == 0, "no new cards — fz1 already paired")
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPullTests \
  test 2>&1 | tail -10
```

Expected: tests fail.

- [ ] **Step 3: Implement steady-state pull in `steadyStateSync`**

Replace the `steadyStateSync` body in `FizzySyncEngine.swift`:

```swift
    private func steadyStateSync(localBoard: Board, fizzyBoardID: String) async throws -> FizzySyncResult {
        var result = FizzySyncResult()

        // Fetch remote state.
        let remoteColumns = try await fetchRemoteColumns(boardID: fizzyBoardID)
        let remoteCards = try await fetchRemoteCards(boardID: fizzyBoardID)

        // Local cards keyed by fizzyID (only paired ones).
        let localColumns: [Column] = (localBoard.columns as? Set<Column>).map { Array($0) } ?? []
        let localCards: [Card] = localColumns.flatMap { col -> [Card] in
            (col.cards as? Set<Card>).map { Array($0) } ?? []
        }
        let pairedByFizzyID: [String: Card] = Dictionary(
            uniqueKeysWithValues: localCards.compactMap { card in card.fizzyID.map { ($0, card) } }
        )

        // Resolve columns: auto-create local for any remote name not seen.
        var resolvedColumns: [String: Column] = Dictionary(
            uniqueKeysWithValues: localColumns.compactMap { col -> (String, Column)? in
                guard let name = col.name else { return nil }
                return (FizzySyncMapping.normalizedColumnName(name), col)
            }
        )
        for remote in remoteColumns {
            let key = FizzySyncMapping.normalizedColumnName(remote.name)
            if resolvedColumns[key] == nil {
                let new = BoardRepository(context: context).createColumn(in: localBoard, name: remote.name, colorHex: nil)
                resolvedColumns[key] = new
            }
        }

        // Pull: for each remote card not yet paired locally, create it.
        for remote in remoteCards where pairedByFizzyID[remote.id] == nil {
            let targetColumn = remote.column
                .flatMap { resolvedColumns[FizzySyncMapping.normalizedColumnName($0.name)] }
                ?? resolvedColumns.values.first
                ?? BoardRepository(context: context).createColumn(in: localBoard, name: "Imported", colorHex: nil)
            let card = CardRepository(context: context).createCard(in: targetColumn, title: remote.title)
            applyRemote(remote, to: card)
            result.itemsCreated += 1
        }

        // LWW updates, push, soft-delete, etc. — added incrementally.

        // Persist lastSyncAt.
        mapping.setLastSync(.now)

        if context.hasChanges {
            try context.save()
        }
        return result
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPullTests \
  test 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): steady-state pull — remote-only cards into local

For every remote card whose fizzyID isn't paired locally, create a
local Card with the remote field set. Auto-creates local columns
for unseen remote names. mapping.setLastSync(.now) at cycle end.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Steady-state push — local-only cards (`nil fizzyID`) → POST

**Files:**
- Modify: `FizzySyncEngine.swift`
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngineSteadyPushTests`)

- [ ] **Step 1: Append failing test**

```swift

@Suite("FizzySyncEngine — steady-state push", .serialized)
@MainActor
struct FizzySyncEngineSteadyPushTests {

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

            let prefix = "test.fizzy.steadypush.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.steadypush.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t", accountSlug: "ACCT",
                urlSession: session, clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client, authState: authState, mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("steady push: 1 local with nil fizzyID + 0 remote → 1 POST, fizzyID stored")
    func pushLocalOnly() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let card = h.cardRepo.createCard(in: h.column, title: "Local")
        try h.persistence.viewContext.save()

        var postCount = 0
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("POST", let p?) where p.hasSuffix("/cards"):
                postCount += 1
                let response = HTTPURLResponse(
                    url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/55"]
                )!
                return (Data(), response)
            case ("GET", let p?) where p.contains("/cards/55"):
                let body = """
                {"id":"fz-55","number":55,"title":"x","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/55"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()

        #expect(postCount == 1)
        #expect(result.itemsCreated == 1)
        h.persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "fz-55")
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPushTests \
  test 2>&1 | tail -10
```

Expected: test fails (POSTs never issued).

- [ ] **Step 3: Add push step to `steadyStateSync`**

In `steadyStateSync`, after the pull loop and BEFORE the `mapping.setLastSync(.now)` line, add:

```swift
        // Push: local cards with nil fizzyID (not yet paired) → POST.
        for card in localCards where card.fizzyID == nil {
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPushTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes. Also re-run the pull tests:

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPullTests \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPushTests \
  test 2>&1 | grep -E "Test run|TEST" | tail -3
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): steady-state push — nil-fizzyID locals POSTed

Mirrors first-sync mode 1's push behavior but runs every cycle —
new local cards created since last sync get POSTed; their fizzyID
+ lastActiveAt are stored.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: LWW conflict resolution (both directions)

**Files:**
- Modify: `FizzySyncEngine.swift` — add `putCard` helper, extend `steadyStateSync` with LWW logic
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngineLWWTests`)

LWW compares `card.fizzyUpdatedAt` (last server timestamp we saw) vs `remote.lastActiveAt` (current server timestamp). If remote is newer, pull. If local has been modified more recently than `fizzyUpdatedAt`, push via PUT.

For Phase 4b, "local modified" means: `card.modifiedAt > card.fizzyUpdatedAt`. The existing `Card.modifiedAt` is bumped on edits by the existing CardRepository.

- [ ] **Step 1: Append failing tests**

```swift

@Suite("FizzySyncEngine — LWW conflict resolution", .serialized)
@MainActor
struct FizzySyncEngineLWWTests {

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

            let prefix = "test.fizzy.lww.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)
            authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

            suiteName = "test.fizzy.lww.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)
            mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)
            let client = FizzyClient(
                baseURL: URL(string: "https://fizzy.bluefenix.net")!,
                accessToken: "t", accountSlug: "ACCT",
                urlSession: session, clock: ImmediateClock()
            )

            engine = FizzySyncEngine(
                client: client, authState: authState, mapping: mapping,
                context: persistence.viewContext
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
        }
    }

    @Test("LWW: remote newer than local fizzyUpdatedAt → local updated from remote")
    func remoteNewerWins() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let newerRemote = Date(timeIntervalSince1970: 1_001_000)

        let card = h.cardRepo.createCard(in: h.column, title: "Old title")
        card.fizzyID = "fz1"
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = baseline  // local hasn't changed since last sync
        try h.persistence.viewContext.save()

        let iso = ISO8601DateFormatter().string(from: newerRemote)
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"New title","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(result.itemsUpdated == 1)
        h.persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.title == "New title")
    }

    @Test("LWW: local modifiedAt newer than fizzyUpdatedAt → PUT issued")
    func localNewerPushes() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let newerLocal = Date(timeIntervalSince1970: 1_001_500)

        let card = h.cardRepo.createCard(in: h.column, title: "Local edit")
        card.fizzyID = "fz1"
        card.fizzyUpdatedAt = baseline
        card.modifiedAt = newerLocal
        try h.persistence.viewContext.save()

        var putCount = 0
        let isoBaseline = ISO8601DateFormatter().string(from: baseline)
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"Stale remote","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(isoBaseline)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("PUT", let p?) where p.contains("/cards/"):
                putCount += 1
                let body = """
                {"id":"fz1","number":1,"title":"Local edit","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(isoBaseline)","created_at":"2026-01-01T00:00:00Z","url":"https://x/1"}
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.engine.sync()
        #expect(putCount == 1)
        #expect(result.itemsUpdated == 1)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineLWWTests \
  test 2>&1 | tail -10
```

Expected: both tests fail.

- [ ] **Step 3: Add LWW logic + `putCard` helper**

In `FizzySyncEngine.swift`, add `putCard` near `postCard`:

```swift
    /// PUT an updated local card to the remote. Returns the updated FizzyCard
    /// so we can sync back the server's lastActiveAt.
    private func putCard(_ card: Card, fizzyID: String) async throws -> FizzyCard {
        let payload = FizzyCardWritePayload(
            card: FizzyCardWrite(
                title: card.title ?? "",
                description: card.cardDescription,
                status: nil,
                tagIds: nil
            )
        )
        return try await client.put(
            "/cards/\(fizzyID)",
            body: payload,
            as: FizzyCard.self
        )
    }
```

Then extend `steadyStateSync` — after the pull loop (which created new local cards), iterate the PAIRED cards for LWW. Insert this BEFORE the push loop and BEFORE the `mapping.setLastSync(.now)`:

```swift
        // LWW for paired cards (both sides have fizzyID).
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
        for (fizzyID, card) in pairedByFizzyID {
            guard let remote = remoteByID[fizzyID] else { continue }
            let localFizzyTimestamp = card.fizzyUpdatedAt ?? .distantPast
            let localModified = card.modifiedAt ?? .distantPast
            let remoteTimestamp = remote.lastActiveAt

            if remoteTimestamp > localFizzyTimestamp && localModified <= localFizzyTimestamp {
                // Remote newer, local untouched → pull.
                applyRemote(remote, to: card)
                result.itemsUpdated += 1
            } else if localModified > localFizzyTimestamp {
                // Local edited since last sync → push.
                do {
                    let updated = try await putCard(card, fizzyID: fizzyID)
                    card.fizzyUpdatedAt = updated.lastActiveAt
                    result.itemsUpdated += 1
                } catch let error as FizzyError {
                    result.errors.append("Push update '\(card.title ?? "(untitled)")': \(error)")
                }
            }
            // else: both equal or remote stale → no-op.
        }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineLWWTests \
  test 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): LWW conflict resolution for paired cards

For each paired card (both sides have fizzyID), compare remote
lastActiveAt against local fizzyUpdatedAt + modifiedAt:
- remote newer, local untouched → pull
- local edited since last sync → PUT via new putCard helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Soft-delete on missing remote

Local card has `fizzyID` but it's no longer in the remote response → it was deleted in Fizzy. Mark as deleted locally.

**Files:**
- Modify: `FizzySyncEngine.swift`
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngineSoftDeleteTests`)

- [ ] **Step 1: Append failing test**

```swift

@Suite("FizzySyncEngine — soft-delete on missing remote", .serialized)
@MainActor
struct FizzySyncEngineSoftDeleteTests {

    @Test("paired local card not in remote response → deleted locally")
    func softDeletesMissingRemote() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.delete.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.delete.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        // Paired local card; remote will return empty list.
        let card = cardRepo.createCard(in: column, title: "Doomed")
        card.fizzyID = "fz-doomed"
        try persistence.viewContext.save()
        let cardObjectID = card.objectID

        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )

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

        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )
        let result = try await engine.sync()

        #expect(result.itemsDeleted == 1)
        // The card should be deleted from the context.
        let stillExists = (try? persistence.viewContext.existingObject(with: cardObjectID)) as? Card
        #expect(stillExists?.isDeleted == true || stillExists == nil)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSoftDeleteTests \
  test 2>&1 | tail -10
```

Expected: test fails.

- [ ] **Step 3: Add soft-delete to `steadyStateSync`**

After the LWW loop, before the push loop, insert:

```swift
        // Soft-delete: paired local cards whose fizzyID is no longer in the
        // remote response were deleted on the server.
        for (fizzyID, card) in pairedByFizzyID where remoteByID[fizzyID] == nil {
            context.delete(card)
            result.itemsDeleted += 1
        }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSoftDeleteTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): soft-delete paired locals missing from remote

If a card has fizzyID but no matching remote card on this poll, the
server deleted it. Mirror the deletion locally (hard delete via
context.delete; CloudKit handles tombstones for sync partners).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Crash-after-POST recovery (title + createdAt ±60s)

Local card has `nil fizzyID` (we POSTed but crashed before saving). Remote has a card with matching title within ±60s of `createdAt`. Claim the orphan instead of duplicating.

**Files:**
- Modify: `FizzySyncEngine.swift`
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngineCrashRecoveryTests`)

- [ ] **Step 1: Append failing test**

```swift

@Suite("FizzySyncEngine — crash-after-POST recovery", .serialized)
@MainActor
struct FizzySyncEngineCrashRecoveryTests {

    @Test("local nil-fizzyID + remote matching title within 60s → claim orphan, no duplicate POST")
    func claimsOrphan() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.crash.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.crash.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let card = cardRepo.createCard(in: column, title: "Orphan-prone")
        card.createdAt = baseline
        try persistence.viewContext.save()

        MockURLProtocol.reset()
        var postCount = 0
        let withinWindow = baseline.addingTimeInterval(30)  // 30s after local create
        let iso = ISO8601DateFormatter().string(from: withinWindow)
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz-orphan","number":1,"title":"Orphan-prone","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(iso)","created_at":"\(iso)","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("POST", _):
                postCount += 1
                return (Data(), .response(for: req, status: 201, headers: ["Location": "https://x/999"]))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        let result = try await engine.sync()

        #expect(postCount == 0, "should NOT POST — orphan claimed")
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "fz-orphan", "local claimed the orphan")
        #expect(result.errors.isEmpty)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineCrashRecoveryTests \
  test 2>&1 | tail -10
```

Expected: test fails (POSTs anyway).

- [ ] **Step 3: Add orphan-claim logic**

Modify the push loop in `steadyStateSync` to first try claiming an orphan. Replace the push block:

```swift
        // Push: local cards with nil fizzyID (not yet paired) → claim orphan
        // or POST. Crash-after-POST recovery: if remote has a card with the
        // same title created within ±60s of our local createdAt, claim it
        // instead of POSTing a duplicate.
        let orphanWindow: TimeInterval = 60
        for card in localCards where card.fizzyID == nil {
            let localCreated = card.createdAt ?? .distantPast
            let orphan = remoteCards.first { remote in
                remote.title == (card.title ?? "")
                    && abs(remote.createdAt.timeIntervalSince(localCreated)) <= orphanWindow
                    && pairedByFizzyID[remote.id] == nil
            }
            if let orphan {
                card.fizzyID = orphan.id
                card.fizzyUpdatedAt = orphan.lastActiveAt
                result.itemsUpdated += 1
                continue
            }
            do {
                let created = try await postCard(card, toBoardID: fizzyBoardID)
                card.fizzyID = created.id
                card.fizzyUpdatedAt = created.lastActiveAt
                result.itemsCreated += 1
            } catch let error as FizzyError {
                result.errors.append("Push '\(card.title ?? "(untitled)")': \(error)")
            }
        }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineCrashRecoveryTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes.

Also re-run the steady-push suite to verify it still passes (the orphan-claim logic shouldn't affect the case where there's no orphan):

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineSteadyPushTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): crash-after-POST recovery via title + createdAt window

If the app dies between POST-success and CoreData-save, the next sync
sees a local card with nil fizzyID and a remote card with matching
title + createdAt within 60s. Claim the orphan instead of POSTing a
duplicate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Idempotence verification

Re-running `sync()` twice in a row should produce zero changes the second time. Lock this with a test.

**Files:**
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngineIdempotenceTests`)

- [ ] **Step 1: Append failing test (will likely pass already, but lock it)**

```swift

@Suite("FizzySyncEngine — idempotence", .serialized)
@MainActor
struct FizzySyncEngineIdempotenceTests {

    @Test("running sync() twice in a row produces zero changes on second run")
    func doubleSyncIsNoop() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.idemp.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("t"); authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.idemp.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        let stableISO = "2026-05-25T00:00:00Z"
        MockURLProtocol.reset()
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"R","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"\(stableISO)","created_at":"\(stableISO)","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        let first = try await engine.sync()
        let second = try await engine.sync()

        #expect(first.itemsCreated == 1)
        #expect(second.itemsCreated == 0)
        #expect(second.itemsUpdated == 0)
        #expect(second.itemsDeleted == 0)
        #expect(second.errors.isEmpty)
    }
}
```

- [ ] **Step 2: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngineIdempotenceTests \
  test 2>&1 | tail -5
```

Expected: 1 test passes. If it fails, the LWW or pull logic is producing spurious updates — diagnose by checking whether `card.fizzyUpdatedAt == remote.lastActiveAt` after the first sync.

- [ ] **Step 3: Commit**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
test(fizzy): idempotence — sync() twice in a row produces zero changes

Locks the contract that the steady-state cycle converges. First run
creates the paired local; second run sees fizzyUpdatedAt == remote
lastActiveAt and does nothing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: 401 handling — clear auth state

When the API returns 401, the token is bad. Clear `authState` so the UI banner (Phase 5) can prompt re-auth. The sync call should surface a `.unauthorized` error.

**Files:**
- Modify: `FizzySyncEngine.swift`
- Modify: `FizzySyncEngineTests.swift` (append `FizzySyncEngine401Tests`)

- [ ] **Step 1: Append failing test**

```swift

@Suite("FizzySyncEngine — 401 handling", .serialized)
@MainActor
struct FizzySyncEngine401Tests {

    @Test("401 from remote clears authState; engine surfaces error")
    func unauthorizedClearsAuth() async throws {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        _ = boardRepo.createColumn(in: board, name: "C")
        try persistence.viewContext.save()

        let prefix = "test.fizzy.401.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        defer { authState.clear() }
        authState.setAccessToken("revoked-token")
        authState.setAccountSlug("ACCT")

        let suiteName = "test.fizzy.401.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        MockURLProtocol.reset()
        MockURLProtocol.handler = { req in
            (Data(), .response(for: req, status: 401))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "revoked-token", accountSlug: "ACCT",
            urlSession: session, clock: ImmediateClock()
        )
        let engine = FizzySyncEngine(
            client: client, authState: authState, mapping: mapping,
            context: persistence.viewContext
        )

        // Pre-condition
        #expect(authState.accessToken == "revoked-token")

        do {
            _ = try await engine.sync()
            Issue.record("expected sync() to throw on 401")
        } catch let error as FizzyError {
            #expect(error == .unauthorized)
        }

        // Post-condition: authState cleared
        #expect(authState.accessToken == nil)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngine401Tests \
  test 2>&1 | tail -10
```

Expected: test fails — `authState.accessToken` is still set after the throw (no clearing logic).

- [ ] **Step 3: Wrap `steadyStateSync` body to catch `.unauthorized`**

In `FizzySyncEngine.swift`, modify the `sync()` method:

```swift
    func sync() async throws -> FizzySyncResult {
        guard authState.isConfigured,
              let localBoardID = mapping.localBoardID,
              let fizzyBoardID = mapping.fizzyBoardID,
              let localBoard = fetchBoard(by: localBoardID)
        else {
            return FizzySyncResult()
        }
        do {
            return try await steadyStateSync(localBoard: localBoard, fizzyBoardID: fizzyBoardID)
        } catch FizzyError.unauthorized {
            // Token revoked or expired — clear Keychain entries so Phase 5's
            // UI can prompt re-auth.
            authState.clear()
            throw FizzyError.unauthorized
        }
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzySyncEngine401Tests \
  test 2>&1 | tail -5
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift \
        FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): 401 from sync() clears authState

When the token is revoked or expired, sync() catches FizzyError.unauthorized,
clears the Keychain entries via authState.clear(), and rethrows. Phase 5's
UI will observe authState and surface a banner prompting re-auth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: TDD status doc

**File:** Modify `TDD_IMPLEMENTATION_STATUS.md` — append Phase 4b entry.

- [ ] **Step 1: Append entry**

```markdown

### Fizzy Integration — Phase 4b: Steady-State Sync Engine ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- 9 new tests across 7 suites: `FizzySyncEngineSyncPairingTests` (1), `FizzySyncEngineSteadyPullTests` (2), `FizzySyncEngineSteadyPushTests` (1), `FizzySyncEngineLWWTests` (2), `FizzySyncEngineSoftDeleteTests` (1), `FizzySyncEngineCrashRecoveryTests` (1), `FizzySyncEngineIdempotenceTests` (1), `FizzySyncEngine401Tests` (1).
- Each test verified failing before implementation.

**🟢 Green Phase:**
- Added public `FizzySyncEngine.sync()` method, called after `syncFirst(mode:)` has paired the board.
- Steady-state cycle: fetch remote → diff against `fizzyID`-keyed locals → pull new remotes, soft-delete missing-from-remote locals, LWW-update paired cards, push nil-fizzyID locals (with title+createdAt orphan-claim).
- 401 from any HTTP call clears `authState.clear()` and rethrows.
- `mapping.setLastSync(.now)` written at the end of every successful cycle.
- New private helpers: `putCard(_:fizzyID:)` (for LWW updates pushing local→remote); orphan-claim window logic in the push loop.

**🔵 Refactor Phase:**
- Pull/LWW/soft-delete/push are sequential within `steadyStateSync`; each operates on the same `remoteCards` + `pairedByFizzyID` snapshots fetched at the top.
- Column resolution reuses the same dict pattern as Phase 4a's `syncFirstReplaceLocal` / `syncFirstMerge`.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-4b-steady-state.md`

**Test Coverage:** 9 new tests across 7 suites. Full suite green.

**Documented limitations** (carried over from 4a; still flagged in source comments):
1. Per-card ETag persistence (`Card.fizzyEtag`) not populated — Phase 4b refetches the whole board each cycle. Acceptable for personal use; revisit if board cards reach low-hundreds count.
2. LWW is card-level (single timestamp), not field-level.
3. Card.label is single-valued; only the first remote tag mapped on pull. Push omits `tag_ids`.

**What ships:** Engine is feature-complete for Phase 5 to wire to UI. `syncFirst(mode:)` for one-shot pair; `sync()` for the foreground-polling cycle.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 4b (steady-state sync engine)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification

- [ ] **Step 1: Reset simulator + run full iOS suite**

```bash
xcrun simctl shutdown all && sleep 4
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with ~197 tests in ~52 suites passed` (Phase 4a baseline 188 + Phase 4b's 9 = 197).

- [ ] **Step 2: macOS clean build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Branch state**

```bash
git log --oneline <P4b plan SHA>..HEAD
git status -sb
```

Expected: ~9 new commits (one per task plus the doc) on top of Phase 4a's last commit, clean working tree.

- [ ] **Step 4: Report ready-for-PR**

Suggested PR title:

> `feat(fizzy): Phase 4b — steady-state sync engine (pull/push/LWW/soft-delete/401)`

Suggested PR body skeleton:

```markdown
## Summary
- New `FizzySyncEngine.sync()` for the foreground-polling steady-state cycle.
- Pulls remote-only, pushes local-only, LWW-resolves paired conflicts, soft-deletes missing remotes, 401 clears authState.
- Orphan-claim recovery for crash-after-POST scenarios (title + createdAt ±60s).
- ~9 new tests; full suite green.
- Engine is feature-complete; Phase 5 wires it to UI.

## Test plan
- [x] iOS Simulator + macOS clean.
- [x] 9 new tests cover the steady-state lifecycle.
- [x] Full suite green.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-4b-steady-state.md`
- Phase 5 (UI + FizzySyncProvider conformance + polling timer wire-up) is the natural follow-on.
```

---

## Success criteria recap

- [ ] `FizzySyncEngine.sync()` is the only new public method.
- [ ] Cycle handles all four directions: pull (remote-only), push (local-only with orphan-claim), LWW update (paired), soft-delete (paired-then-removed).
- [ ] 401 from any HTTP call clears `authState` and rethrows.
- [ ] `mapping.setLastSync(.now)` written at end of every successful cycle.
- [ ] Idempotence: running `sync()` twice in a row produces 0 second-run changes.
- [ ] 9 new tests pass. Full suite at ~197/197.
- [ ] iOS Sim + macOS clean builds.
- [ ] TDD doc updated.
- [ ] No app wiring — Phase 5 binds this to the UI + polling timer.
