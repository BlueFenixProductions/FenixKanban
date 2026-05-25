# Fizzy Integration — Phase 2: Auth State + Board Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Fizzy credentials (token + slug + baseURL) in Keychain and the singleton local↔Fizzy board pairing in UserDefaults. No UI, no sync engine wiring yet.

**Architecture:** Two small instance types — `FizzyAuthState` (wraps `KeychainHelper` via injected key prefix for test isolation) and `FizzyBoardMapping` (wraps an injected `UserDefaults`). Both expose typed properties + a `clear()` reset. Production code uses the default instances; tests inject custom prefixes / suites so the Keychain and shared defaults stay clean.

**Tech Stack:** Swift 6, `KeychainHelper` (existing, in `AuthenticationService.swift:80`), `Foundation.UserDefaults`, `Foundation.UUID`, ISO8601 dates, Swift Testing (`@Test`/`@Suite`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md` (§ Data model)

**Out of scope for Phase 2** (deferred):
- CoreData migration for `Card.fizzyID/fizzyEtag/fizzyUpdatedAt` — Phase 3
- `FizzySyncEngine` — Phase 4
- `FizzyAuthView` + `SyncSettingsView` rewrite — Phase 5
- Foreground polling timer + `CardView` cloud badges — Phase 6
- `FizzySyncProvider` registration in `FenixKanbanApp.init()` — Phase 5 (needs Engine + UI first)
- The orchestrating `signOut()` that nukes Keychain + Mapping + per-Card sync columns — Phase 5

---

## File Structure

**New source files:**
- `FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift` — Keychain-backed `accessToken` / `accountSlug` / `baseURL` (~60 LOC)
- `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift` — UserDefaults-backed pairing + `lastSyncAt` (~70 LOC)

**New test files:**
- `FenixKanbanTests/Services/Fizzy/FizzyAuthStateTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzyBoardMappingTests.swift`

**Modified:**
- `TDD_IMPLEMENTATION_STATUS.md` — append Phase 2 entry

**No `project.yml` change** — new files land in `FenixKanban/Core/Services/Fizzy/` and `FenixKanbanTests/Services/Fizzy/`, both directories XcodeGen already sources recursively.

---

## Task 1: `FizzyBoardMapping` (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyBoardMappingTests.swift`

`FizzyBoardMapping` wraps three `UserDefaults` keys for the singleton pairing. Constructor takes an injected `UserDefaults` so tests use a private suite that doesn't touch the user's real defaults.

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzyBoardMappingTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardMapping", .serialized)
struct FizzyBoardMappingTests {

    private let suiteName: String
    private let defaults: UserDefaults
    private let mapping: FizzyBoardMapping

    init() {
        // Unique suite per test instance so parallel test runs and the user's
        // real .standard defaults stay untouched.
        suiteName = "test.fizzy.mapping.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        mapping = FizzyBoardMapping(defaults: defaults)
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("default state: unpaired, nil ids, nil lastSyncAt")
    func defaultState() {
        defer { tearDown() }
        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)
        #expect(mapping.isPaired == false)
    }

    @Test("setPairing stores both IDs and isPaired flips true")
    func setPairing() {
        defer { tearDown() }
        let localID = UUID()
        mapping.setPairing(localBoardID: localID, fizzyBoardID: "fizzy-123")

        #expect(mapping.localBoardID == localID)
        #expect(mapping.fizzyBoardID == "fizzy-123")
        #expect(mapping.isPaired == true)
    }

    @Test("setLastSync round-trips an ISO8601 date")
    func lastSyncRoundTrip() throws {
        defer { tearDown() }
        let now = Date(timeIntervalSince1970: 1_734_567_890)  // fixed instant for stability
        mapping.setLastSync(now)

        let read = try #require(mapping.lastSyncAt)
        // ISO8601 second precision is enough; allow ±1s tolerance for fractional rounding.
        #expect(abs(read.timeIntervalSince(now)) < 1)
    }

    @Test("clear() removes all three keys; isPaired returns to false")
    func clearResets() {
        defer { tearDown() }
        mapping.setPairing(localBoardID: UUID(), fizzyBoardID: "x")
        mapping.setLastSync(Date())
        #expect(mapping.isPaired == true)

        mapping.clear()

        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)
        #expect(mapping.isPaired == false)
    }
}
```

- [ ] **Step 2: Regenerate + run the failing tests**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyBoardMappingTests \
  test 2>&1 | tail -20
```

Expected: build fails with `Cannot find 'FizzyBoardMapping' in scope`.

- [ ] **Step 3: Implement `FizzyBoardMapping`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift`):

```swift
import Foundation

/// Persists the singleton pairing between one local `Board` and one Fizzy board.
///
/// Storage lives in the injected `UserDefaults` (default `.standard`). Tests
/// pass a private `UserDefaults(suiteName:)` so they never touch the user's
/// real defaults.
///
/// Phase 2 of the Fizzy integration; Phase 4's sync engine reads this to decide
/// what to sync, and Phase 5's `FizzyAuthView` writes it after the user picks
/// a pair.
final class FizzyBoardMapping {

    private static let localBoardKey = "fizzy.pairing.localBoardID"
    private static let fizzyBoardKey = "fizzy.pairing.fizzyBoardID"
    private static let lastSyncKey   = "fizzy.pairing.lastSyncAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UUID of the paired local FenixKanban `Board`, or `nil` if unpaired.
    var localBoardID: UUID? {
        guard let string = defaults.string(forKey: Self.localBoardKey) else { return nil }
        return UUID(uuidString: string)
    }

    /// Opaque Fizzy board ID (e.g. `"03f5v9zkft4hj9qq0lsn9ohcm"`), or `nil`.
    var fizzyBoardID: String? {
        defaults.string(forKey: Self.fizzyBoardKey)
    }

    /// Timestamp of the most recent successful sync, or `nil` if never synced.
    var lastSyncAt: Date? {
        guard let string = defaults.string(forKey: Self.lastSyncKey) else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    /// `true` when both IDs are present — the predicate gating sync.
    var isPaired: Bool {
        localBoardID != nil && fizzyBoardID != nil
    }

    /// Sets both pairing IDs atomically (the two underlying defaults writes are
    /// not transactional, but they live in the same suite and complete before
    /// the next read).
    func setPairing(localBoardID: UUID, fizzyBoardID: String) {
        defaults.set(localBoardID.uuidString, forKey: Self.localBoardKey)
        defaults.set(fizzyBoardID, forKey: Self.fizzyBoardKey)
    }

    /// Records a successful sync.
    func setLastSync(_ date: Date) {
        defaults.set(ISO8601DateFormatter().string(from: date), forKey: Self.lastSyncKey)
    }

    /// Removes all three keys.
    func clear() {
        defaults.removeObject(forKey: Self.localBoardKey)
        defaults.removeObject(forKey: Self.fizzyBoardKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
    }
}
```

- [ ] **Step 4: Run tests + verify pass**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyBoardMappingTests \
  test 2>&1 | tail -15
```

Expected: 4 tests pass, `** TEST SUCCEEDED **`. If the simulator returns "Busy", `xcrun simctl shutdown all && sleep 3` then retry.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift \
        FenixKanbanTests/Services/Fizzy/FizzyBoardMappingTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyBoardMapping — UserDefaults pairing state

Singleton local↔Fizzy board pairing + lastSyncAt timestamp.
Injected UserDefaults so tests use private suites without
touching the user's real defaults.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

⚠️ If `make generate` modifies `FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme`, do NOT include the scheme file in the commit — `git checkout HEAD --` it back before staging.

---

## Task 2: `FizzyAuthState` (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyAuthStateTests.swift`

`FizzyAuthState` wraps three Keychain keys for credentials. The class accepts a `keyPrefix` constructor parameter so tests can use a unique prefix per run — Keychain entries are real OS state and would otherwise persist across test runs and pollute the real `fizzy.*` entries.

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzyAuthStateTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyAuthState", .serialized)
struct FizzyAuthStateTests {

    private let prefix: String
    private let state: FizzyAuthState

    init() {
        // Unique prefix per test so Keychain entries from one test don't bleed
        // into another, and prod `fizzy.*` entries on the simulator are safe.
        prefix = "test.fizzy.\(UUID().uuidString)"
        state = FizzyAuthState(keyPrefix: prefix)
    }

    private func tearDown() {
        state.clear()
    }

    @Test("default state: nil token, nil slug, default baseURL, not configured")
    func defaultState() {
        defer { tearDown() }
        #expect(state.accessToken == nil)
        #expect(state.accountSlug == nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
        #expect(state.isConfigured == false)
    }

    @Test("setAccessToken + setAccountSlug round-trip; isConfigured flips true")
    func tokenAndSlugRoundTrip() {
        defer { tearDown() }
        state.setAccessToken("claude-dev-token")
        state.setAccountSlug("897362094")

        #expect(state.accessToken == "claude-dev-token")
        #expect(state.accountSlug == "897362094")
        #expect(state.isConfigured == true)
    }

    @Test("setBaseURL overrides default; nil reverts to default")
    func baseURLOverrideAndRevert() throws {
        defer { tearDown() }
        let custom = URL(string: "http://localhost:3006")!
        state.setBaseURL(custom)
        #expect(state.baseURL == custom)

        state.setBaseURL(nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
    }

    @Test("clear() removes all three keys; isConfigured returns to false")
    func clearResets() {
        // Don't `defer tearDown()` here — `clear()` IS what we're testing.
        state.setAccessToken("t")
        state.setAccountSlug("s")
        state.setBaseURL(URL(string: "http://localhost:3006")!)
        #expect(state.isConfigured == true)

        state.clear()

        #expect(state.accessToken == nil)
        #expect(state.accountSlug == nil)
        #expect(state.baseURL == FizzyAuthState.defaultBaseURL)
        #expect(state.isConfigured == false)
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyAuthStateTests \
  test 2>&1 | tail -15
```

Expected: build fails with `Cannot find 'FizzyAuthState' in scope`.

- [ ] **Step 3: Implement `FizzyAuthState`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift`):

```swift
import Foundation

/// Persists Fizzy credentials (Bearer token, account slug, base URL) in the
/// Keychain via the project's `KeychainHelper`.
///
/// Production uses the default `keyPrefix` of `"fizzy"`, producing the three
/// keys named in the spec: `fizzy.accessToken`, `fizzy.accountSlug`,
/// `fizzy.baseURL`. Tests pass a unique prefix so concurrent test runs and
/// the user's real credentials on the simulator stay isolated.
///
/// Phase 2 of the Fizzy integration; Phase 5's `FizzyAuthView` writes via the
/// `set*` methods, and Phase 4's sync engine + Phase 5's `FizzySyncProvider`
/// read via the properties.
final class FizzyAuthState {

    /// Default Fizzy server. User-overridable via `setBaseURL` so a developer
    /// can repoint at a localhost Fizzy instance without rebuilding the app.
    static let defaultBaseURL = URL(string: "https://fizzy.bluefenix.net")!

    let keyPrefix: String

    init(keyPrefix: String = "fizzy") {
        self.keyPrefix = keyPrefix
    }

    private var tokenKey: String  { "\(keyPrefix).accessToken" }
    private var slugKey: String   { "\(keyPrefix).accountSlug" }
    private var urlKey: String    { "\(keyPrefix).baseURL" }

    /// Bearer personal access token (e.g. `claude-dev`). `nil` when not configured.
    var accessToken: String? {
        KeychainHelper.load(key: tokenKey)
    }

    /// Account-slug segment (e.g. `"897362094"`) interpolated into URLs by
    /// `FizzyClient`. `nil` when not configured.
    var accountSlug: String? {
        KeychainHelper.load(key: slugKey)
    }

    /// Effective base URL. Returns the user-overridden value if set, else
    /// `defaultBaseURL`.
    var baseURL: URL {
        guard let string = KeychainHelper.load(key: urlKey),
              let url = URL(string: string)
        else { return Self.defaultBaseURL }
        return url
    }

    /// `true` when both `accessToken` and `accountSlug` are present.
    var isConfigured: Bool {
        accessToken != nil && accountSlug != nil
    }

    /// Sets or clears the access token. `nil` removes the Keychain entry.
    func setAccessToken(_ value: String?) {
        write(value, key: tokenKey)
    }

    /// Sets or clears the account slug.
    func setAccountSlug(_ value: String?) {
        write(value, key: slugKey)
    }

    /// Overrides the base URL. `nil` reverts to `defaultBaseURL`.
    func setBaseURL(_ value: URL?) {
        write(value?.absoluteString, key: urlKey)
    }

    /// Removes all three Keychain entries; `baseURL` reverts to default.
    func clear() {
        KeychainHelper.delete(key: tokenKey)
        KeychainHelper.delete(key: slugKey)
        KeychainHelper.delete(key: urlKey)
    }

    private func write(_ value: String?, key: String) {
        if let value {
            KeychainHelper.save(key: key, value: value)
        } else {
            KeychainHelper.delete(key: key)
        }
    }
}
```

- [ ] **Step 4: Run tests + verify pass**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyAuthStateTests \
  test 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift \
        FenixKanbanTests/Services/Fizzy/FizzyAuthStateTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyAuthState — Keychain-backed credentials wrapper

Bearer token (claude-dev PAT), account slug, and overridable base
URL stored under `fizzy.*` Keychain keys. Constructor takes a
key prefix so tests use a unique namespace without touching the
user's real Fizzy credentials.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Document Phase 2 in `TDD_IMPLEMENTATION_STATUS.md`

**File:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` — append a new section at the end

- [ ] **Step 1: Append the entry**

Append to the bottom of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown

### Fizzy Integration — Phase 2: Auth State + Board Mapping ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- Wrote `FizzyBoardMappingTests` (4 tests) against a private `UserDefaults(suiteName:)` — default state, setPairing, lastSyncAt round-trip, clear.
- Wrote `FizzyAuthStateTests` (4 tests) using a unique Keychain `keyPrefix` per test — default state, token+slug round-trip, baseURL override+revert, clear.
- All tests verified failing before implementation.

**🟢 Green Phase:**
- `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift` — instance-based wrapper around 3 `UserDefaults` keys (`fizzy.pairing.localBoardID`, `fizzy.pairing.fizzyBoardID`, `fizzy.pairing.lastSyncAt`). `isPaired` predicate, `setPairing`, `setLastSync`, `clear`.
- `FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift` — instance-based wrapper around 3 Keychain keys (`fizzy.accessToken`, `fizzy.accountSlug`, `fizzy.baseURL`). `isConfigured` predicate, `set*` setters, `clear`, default `baseURL == https://fizzy.bluefenix.net`.

**🔵 Refactor Phase:**
- Both types use injected storage (UserDefaults for mapping, Keychain key prefix for auth) to keep tests fully isolated from production state.
- No protocol abstractions or static-only APIs — instance + injection is the smallest unit of testability.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-2-state.md`

**Test Coverage:** 8 new tests (4 per type). Full suite still green.

**What ships:** Two small persistence types ready for Phase 3 (CoreData migration) and Phase 4 (sync engine) to consume. No app wiring yet — `FizzySyncProvider.register()` and the `signOut()` orchestration land in Phase 5 once the engine + UI exist.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 2 (auth state + board mapping)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Final verification

- [ ] **Step 1: Reset simulator + run the full iOS test suite**

```bash
xcrun simctl shutdown all 2>&1 | tail -1
sleep 3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with ~169 tests in ~37 suites passed` (Phase 1's 161 + Phase 2's 8 = 169). If anything fails, diagnose before continuing.

- [ ] **Step 2: Clean macOS build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`, no new warnings from Phase 2 files.

- [ ] **Step 3: Verify final branch state**

```bash
git log --oneline 5a1effd..HEAD
git status -sb
```

Expected: 3 new commits on top of Phase 1's last commit (`5a1effd`, the Phase 1 TDD doc consolidation). Clean working tree.

- [ ] **Step 4: Report Phase 2 ready**

Phase 2 is local-only by default — same convention Phase 1 used. The user pushes manually when they want CI to run. Suggested PR title if/when they're ready:

> `feat(fizzy): Phase 2 — auth state + board mapping (no UI, no engine)`

Suggested PR body skeleton (do NOT auto-push):

```markdown
## Summary
- New `FizzyAuthState` for Keychain-backed token/slug/baseURL.
- New `FizzyBoardMapping` for UserDefaults-backed singleton pairing + lastSyncAt.
- 8 new tests; full suite green.
- Zero app wiring — Phases 3-6 layer on CoreData migration, sync engine, UI, polling.

## Test plan
- [x] Build clean on iOS Simulator + macOS.
- [x] 8 new tests pass; full suite green.
- [x] Tests use unique Keychain prefixes and private UserDefaults suites — no pollution of real credentials/defaults.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-2-state.md`
```

---

## Success criteria recap

- [ ] `FizzyBoardMapping` exists at the spec'd path with the 6 public members (3 properties, `isPaired`, `setPairing`, `setLastSync`, `clear`).
- [ ] `FizzyAuthState` exists at the spec'd path with the 7 public members (3 properties, `isConfigured`, 3 setters, `clear`, `defaultBaseURL` static).
- [ ] 4 `FizzyBoardMappingTests` pass.
- [ ] 4 `FizzyAuthStateTests` pass.
- [ ] Full iOS test suite passes (~169 tests).
- [ ] macOS clean build succeeds with no new warnings.
- [ ] Tests never touch the user's real Keychain entries (`fizzy.*` namespace) or `.standard` UserDefaults — all storage is namespaced under unique per-test prefixes / suites.
- [ ] `TDD_IMPLEMENTATION_STATUS.md` updated.
- [ ] Branch is local-only — no auto-push.
