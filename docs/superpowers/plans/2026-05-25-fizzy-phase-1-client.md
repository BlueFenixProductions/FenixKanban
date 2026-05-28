# Fizzy Integration — Phase 1: Client + DTOs + Error Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, fully-mocked-tested HTTP client for the Fizzy API. No app integration yet — this phase ships pure plumbing that later phases consume.

**Architecture:** `FizzyClient` is a `URLSession`-backed wrapper that adds Bearer auth, interpolates `:account_slug` into paths, manages `If-None-Match`/`ETag`, follows `POST → 201 + Location` with a chained GET, retries transient failures, and maps HTTP statuses to typed `FizzyError` values. Codable `FizzyDTOs` mirror the wire shapes. Everything is tested against a `MockURLProtocol` — zero live network in CI.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`@Suite`/`#expect`), `URLSession`, `URLProtocol` for mocking, XcodeGen, Foundation `JSONDecoder`/`JSONEncoder`.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md` (§3 Architecture, §6 Errors, §7 Testing)

**Out of scope for Phase 1** (deferred to Phase 2-6):
- `FizzyAuthState` (Keychain wrapper) — Phase 2
- `FizzyBoardMapping` (UserDefaults) — Phase 2
- CoreData migration — Phase 3
- `FizzySyncEngine` — Phase 4
- `FizzyAuthView` + `SyncSettingsView` rewrite — Phase 5
- Foreground polling timer + `CardView` badges — Phase 6

---

## File Structure

**New source files:**
- `FenixKanban/Core/Services/Fizzy/FizzyError.swift` — typed errors (~50 LOC, single enum)
- `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift` — Codable wire shapes (~120 LOC, several structs)
- `FenixKanban/Core/Services/Fizzy/FizzyResponse.swift` — `{ body, etag }` wrapper (~15 LOC)
- `FenixKanban/Core/Services/Fizzy/FizzyClient.swift` — HTTP wrapper (~200 LOC, single class)

**New test files:**
- `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift` — shared test harness
- `FenixKanbanTests/Services/Fizzy/FizzyErrorTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzyDTOTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`

**Test fixtures:**
- `FenixKanbanTests/Fixtures/fizzy/identity.json`
- `FenixKanbanTests/Fixtures/fizzy/boards.json`
- `FenixKanbanTests/Fixtures/fizzy/columns.json`
- `FenixKanbanTests/Fixtures/fizzy/cards.json`
- `FenixKanbanTests/Fixtures/fizzy/card_single.json` (includes `column` field which the list endpoint omits)
- `FenixKanbanTests/Fixtures/fizzy/README.md`

**Modified:**
- `project.yml` — fixtures dir needs to be included as test resources (see Task 1).
- `TDD_IMPLEMENTATION_STATUS.md` — log Phase 1.

---

## Task 1: Test fixtures (hand-transcribed from API docs)

**Files:**
- Create: `FenixKanbanTests/Fixtures/fizzy/identity.json`
- Create: `FenixKanbanTests/Fixtures/fizzy/boards.json`
- Create: `FenixKanbanTests/Fixtures/fizzy/columns.json`
- Create: `FenixKanbanTests/Fixtures/fizzy/cards.json`
- Create: `FenixKanbanTests/Fixtures/fizzy/card_single.json`
- Create: `FenixKanbanTests/Fixtures/fizzy/README.md`
- Modify: `project.yml`

These are transcribed verbatim from `~/Documents/GitHub/fizzy/docs/api/sections/*.md`. No live token needed for Phase 1.

- [ ] **Step 1: Create `identity.json`**

Content (write to `FenixKanbanTests/Fixtures/fizzy/identity.json`):

```json
{
  "accounts": [
    {
      "id": "03f5v9zjskhcii2r45ih3u1rq",
      "name": "BlueFenix",
      "slug": "/897362094",
      "created_at": "2025-12-05T19:36:35.377Z",
      "user": {
        "id": "03f5v9zjw7pz8717a4no1h8a7",
        "name": "Chris Pelatari",
        "role": "owner",
        "active": true,
        "email_address": "chris@bluefenix.net",
        "created_at": "2025-12-05T19:36:35.401Z",
        "url": "https://fizzy.bluefenix.net/897362094/users/03f5v9zjw7pz8717a4no1h8a7"
      }
    }
  ]
}
```

- [ ] **Step 2: Create `boards.json`** (array form, as returned by `GET /:account/boards`)

```json
[
  {
    "id": "03f5v9zkft4hj9qq0lsn9ohcm",
    "name": "Roadmap",
    "all_access": true,
    "created_at": "2025-12-05T19:36:35.534Z",
    "auto_postpone_period_in_days": 30,
    "url": "https://fizzy.bluefenix.net/897362094/boards/03f5v9zkft4hj9qq0lsn9ohcm",
    "creator": {
      "id": "03f5v9zjw7pz8717a4no1h8a7",
      "name": "Chris Pelatari",
      "role": "owner",
      "active": true,
      "email_address": "chris@bluefenix.net",
      "created_at": "2025-12-05T19:36:35.401Z",
      "url": "https://fizzy.bluefenix.net/897362094/users/03f5v9zjw7pz8717a4no1h8a7"
    }
  }
]
```

- [ ] **Step 3: Create `columns.json`**

```json
[
  {
    "id": "03f5v9zkft4hj9qq0lsn9ohcn",
    "name": "Triage",
    "color": { "name": "Slate", "value": "var(--color-card-1)" },
    "created_at": "2025-12-05T19:36:35.534Z"
  },
  {
    "id": "03f5v9zkft4hj9qq0lsn9ohco",
    "name": "In Progress",
    "color": { "name": "Lime", "value": "var(--color-card-4)" },
    "created_at": "2025-12-05T19:36:35.534Z"
  },
  {
    "id": "03f5v9zkft4hj9qq0lsn9ohcp",
    "name": "Review",
    "color": { "name": "Amber", "value": "var(--color-card-7)" },
    "created_at": "2025-12-05T19:36:35.534Z"
  }
]
```

- [ ] **Step 4: Create `cards.json`** (the list endpoint shape — no `column` field per the API docs)

```json
[
  {
    "id": "03f5vaeq985jlvwv3arl4srq2",
    "number": 1,
    "title": "First card",
    "status": "published",
    "description": "Hello, World!",
    "description_html": "<div class=\"action-text-content\"><p>Hello, World!</p></div>",
    "image_url": null,
    "has_attachments": false,
    "tags": ["programming"],
    "golden": false,
    "last_active_at": "2025-12-05T19:38:48.553Z",
    "created_at": "2025-12-05T19:38:48.540Z",
    "url": "https://fizzy.bluefenix.net/897362094/cards/1"
  },
  {
    "id": "03f5vaeq985jlvwv3arl4srq3",
    "number": 2,
    "title": "Golden card",
    "status": "published",
    "description": "This one is golden",
    "description_html": null,
    "image_url": null,
    "has_attachments": false,
    "tags": ["urgent", "bug"],
    "golden": true,
    "last_active_at": "2025-12-05T20:00:00.000Z",
    "created_at": "2025-12-05T19:50:00.000Z",
    "url": "https://fizzy.bluefenix.net/897362094/cards/2"
  },
  {
    "id": "03f5vaeq985jlvwv3arl4srq4",
    "number": 3,
    "title": "Card with image",
    "status": "published",
    "description": null,
    "description_html": null,
    "image_url": "https://fizzy.bluefenix.net/uploads/cards/3.png",
    "has_attachments": true,
    "tags": [],
    "golden": false,
    "last_active_at": "2025-12-05T19:55:00.000Z",
    "created_at": "2025-12-05T19:55:00.000Z",
    "url": "https://fizzy.bluefenix.net/897362094/cards/3"
  }
]
```

- [ ] **Step 5: Create `card_single.json`** (the single-card endpoint with `column` + `steps` fields)

```json
{
  "id": "03f5vaeq985jlvwv3arl4srq2",
  "number": 1,
  "title": "First card",
  "status": "published",
  "description": "Hello, World!",
  "description_html": "<div class=\"action-text-content\"><p>Hello, World!</p></div>",
  "image_url": null,
  "has_attachments": false,
  "tags": ["programming"],
  "closed": false,
  "golden": false,
  "last_active_at": "2025-12-05T19:38:48.553Z",
  "created_at": "2025-12-05T19:38:48.540Z",
  "url": "https://fizzy.bluefenix.net/897362094/cards/1",
  "column": {
    "id": "03f5v9zkft4hj9qq0lsn9ohco",
    "name": "In Progress",
    "color": { "name": "Lime", "value": "var(--color-card-4)" },
    "created_at": "2025-12-05T19:36:35.534Z"
  },
  "steps": [
    { "id": "03f8huu0sog76g3s975963b5e", "content": "Step one", "completed": false },
    { "id": "03f8huu0sog76g3s975969734", "content": "Step two", "completed": true }
  ]
}
```

- [ ] **Step 6: Create the fixture README**

Content (write to `FenixKanbanTests/Fixtures/fizzy/README.md`):

```markdown
# Fizzy API Test Fixtures

Transcribed verbatim from `~/Documents/GitHub/fizzy/docs/api/sections/*.md` (the
37signals Fizzy OSS repo on this machine). These are hand-written, not captured
from a live API — Phase 1 ships before any live token wiring (that comes in
Phase 5).

## When to refresh

Refresh these whenever Fizzy upstream changes a wire format. The trigger is a
test failure on a DTO field name or type mismatch after pulling a newer Fizzy.

### Refresh procedure (post-Phase 5)

Once `FizzyClient` is wired to a real token, capture from the live instance:

```bash
TOKEN=$(security find-generic-password -a chris -s fizzy.accessToken -w)
SLUG=897362094  # your fizzy.bluefenix.net account slug
BASE=https://fizzy.bluefenix.net

curl -sH "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  "$BASE/my/identity" | jq . > identity.json
curl -sH "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  "$BASE/$SLUG/boards" | jq . > boards.json
```

For now (Phase 1), the hand-transcribed fixtures suffice.

## Files

- `identity.json` — `GET /my/identity`
- `boards.json` — `GET /:account/boards`
- `columns.json` — `GET /:account/boards/:board_id/columns`
- `cards.json` — `GET /:account/cards` (list endpoint; no `column` field per Fizzy docs)
- `card_single.json` — `GET /:account/cards/:number` (single-card endpoint; includes `column`, `steps`)
```

- [ ] **Step 7: Wire the fixtures directory into the test target**

In `project.yml`, find the `FenixKanbanTests` target block (around lines 56–75). The `sources:` block currently lists `FenixKanbanTests` as a path. Add a `resources:` key so `xcodegen` packs the fixtures into the test bundle:

Replace this section:

```yaml
  FenixKanbanTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: FenixKanbanTests
        excludes:
          - "**/.DS_Store"
    dependencies:
      - target: FenixKanban
```

With this (add the `resources:` block and the excludes update):

```yaml
  FenixKanbanTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: FenixKanbanTests
        excludes:
          - "**/.DS_Store"
          - "Fixtures/**/*.json"
          - "Fixtures/**/*.md"
    resources:
      - path: FenixKanbanTests/Fixtures
    dependencies:
      - target: FenixKanban
```

The `excludes` keeps fixture JSON/MD files out of the compile sources list (XcodeGen would otherwise try to compile them); the `resources` line packs them into the test bundle so `Bundle(for:)` lookup finds them at runtime.

- [ ] **Step 8: Regenerate Xcode project**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme  # safety net; the schemes: block from the prior PR should preserve it but doesn't hurt
```

Expected: `make generate` completes; scheme is preserved (it now is, post-`0868bf7`).

- [ ] **Step 9: Build to confirm the fixtures are packed correctly**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build-for-testing 2>&1 | tail -10
```

Expected: `** TEST BUILD SUCCEEDED **`. Fixtures are copied into the `.xctest` bundle's Resources.

- [ ] **Step 10: Commit**

```bash
git add FenixKanbanTests/Fixtures/ project.yml FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
test(fizzy): Fizzy API JSON fixtures + test-bundle wiring

Hand-transcribed from ~/Documents/GitHub/fizzy/docs/api/sections/*.md
per spec §7 Testing. project.yml resources: block packs the JSON
into the test bundle so Bundle(for:) lookup resolves them at runtime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `FizzyError` enum (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyError.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyErrorTests.swift`

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzyErrorTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyError")
struct FizzyErrorTests {

    @Test("status code → error mapping")
    func statusMapping() {
        #expect(FizzyError(httpStatus: 401, body: nil) == .unauthorized)
        #expect(FizzyError(httpStatus: 403, body: nil) == .forbidden)
        #expect(FizzyError(httpStatus: 404, body: nil) == .notFound)
        #expect(FizzyError(httpStatus: 422, body: nil) == .validation([]))
        #expect(FizzyError(httpStatus: 500, body: nil) == .server(statusCode: 500))
        #expect(FizzyError(httpStatus: 503, body: nil) == .server(statusCode: 503))
        #expect(FizzyError(httpStatus: 418, body: nil) == .unexpectedStatus(418))
    }

    @Test("422 with field errors parses the body")
    func validationParsesBody() throws {
        let json = """
        { "errors": { "title": ["can't be blank"], "tags": ["max 10 allowed"] } }
        """.data(using: .utf8)!

        let err = FizzyError(httpStatus: 422, body: json)
        // Order-insensitive comparison since dict iteration order isn't stable.
        if case .validation(let messages) = err {
            #expect(Set(messages) == Set(["title: can't be blank", "tags: max 10 allowed"]))
        } else {
            Issue.record("expected .validation, got \(err)")
        }
    }

    @Test("429 retryAfter parses from header value seconds")
    func rateLimitedHeader() {
        #expect(FizzyError(httpStatus: 429, retryAfter: "60") == .rateLimited(retryAfter: 60))
        #expect(FizzyError(httpStatus: 429, retryAfter: "0.5") == .rateLimited(retryAfter: 0.5))
        // Missing header → default 60s
        #expect(FizzyError(httpStatus: 429, retryAfter: nil) == .rateLimited(retryAfter: 60))
        // Garbage header → default 60s
        #expect(FizzyError(httpStatus: 429, retryAfter: "not-a-number") == .rateLimited(retryAfter: 60))
    }

    @Test("Equatable")
    func equatable() {
        #expect(FizzyError.unauthorized == FizzyError.unauthorized)
        #expect(FizzyError.unauthorized != FizzyError.forbidden)
        #expect(FizzyError.server(statusCode: 500) == FizzyError.server(statusCode: 500))
        #expect(FizzyError.server(statusCode: 500) != FizzyError.server(statusCode: 502))
        #expect(FizzyError.validation(["a"]) == FizzyError.validation(["a"]))
        #expect(FizzyError.validation(["a"]) != FizzyError.validation(["b"]))
    }
}
```

- [ ] **Step 2: Regenerate + run the failing tests**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyErrorTests \
  test 2>&1 | tail -20
```

Expected: build fails with `Cannot find 'FizzyError' in scope` (red phase).

- [ ] **Step 3: Implement `FizzyError`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyError.swift`):

```swift
import Foundation

/// Typed errors surfaced by ``FizzyClient`` for callers (sync engine, UI).
///
/// `network` wraps the underlying `URLError`; `decoding` wraps the JSON parse
/// failure. Everything else is a normalized representation of a Fizzy HTTP
/// response.
enum FizzyError: Error, Equatable {
    case unauthorized              // 401 — token revoked/expired
    case forbidden                 // 403 — token lacks scope
    case notFound                  // 404 — resource gone or never existed
    case validation([String])      // 422 — `{ "errors": { field: [msg, ...] } }` flattened to "field: msg" strings
    case rateLimited(retryAfter: TimeInterval)   // 429 — honor Retry-After
    case server(statusCode: Int)   // 5xx
    case network(URLError)         // URLSession-level (DNS, timeout, offline)
    case decoding(String)          // JSON parse failure; carries the description (Error isn't Equatable)
    case unexpectedStatus(Int)     // catch-all

    /// Init from a raw HTTP status + optional response body. Used for non-429 statuses.
    init(httpStatus: Int, body: Data?) {
        switch httpStatus {
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 422: self = .validation(Self.parseValidationErrors(body))
        case 500...599: self = .server(statusCode: httpStatus)
        default:  self = .unexpectedStatus(httpStatus)
        }
    }

    /// Init for 429 specifically — extracts Retry-After.
    init(httpStatus: Int, retryAfter: String?) {
        precondition(httpStatus == 429, "rate-limit initializer only valid for 429")
        let secs = retryAfter.flatMap { TimeInterval($0) } ?? 60
        self = .rateLimited(retryAfter: secs)
    }

    /// Flattens `{ "errors": { "title": ["msg1", "msg2"], "tags": ["msg3"] } }`
    /// into `["title: msg1", "title: msg2", "tags: msg3"]`. Returns empty array
    /// on any parse failure — 422 is still .validation, just without details.
    private static func parseValidationErrors(_ body: Data?) -> [String] {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = json["errors"] as? [String: [String]]
        else { return [] }
        return errors.flatMap { field, msgs in msgs.map { "\(field): \($0)" } }
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyErrorTests \
  test 2>&1 | tail -15
```

Expected: 4 tests pass, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyError.swift \
        FenixKanbanTests/Services/Fizzy/FizzyErrorTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): typed FizzyError for HTTP + network failures

401/403/404/422/429/5xx mapped to discrete cases. 422 flattens
`{errors:{field:[msg]}}` to ["field: msg"] strings. 429 honors
Retry-After header with a 60s default fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `FizzyDTOs` (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyDTOTests.swift`

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzyDTOTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyDTOs decode")
struct FizzyDTOTests {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureLocator.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") else {
            // Fall back to non-subdir layout if the build system flattened resources.
            guard let flatURL = bundle.url(forResource: name, withExtension: "json") else {
                Issue.record("Could not locate fixture \(name).json in test bundle")
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: flatURL)
        }
        return try Data(contentsOf: url)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("identity.json decodes")
    func identity() throws {
        let data = try loadFixture("identity")
        let identity = try decoder.decode(FizzyIdentity.self, from: data)
        #expect(identity.accounts.count == 1)
        let account = try #require(identity.accounts.first)
        #expect(account.id == "03f5v9zjskhcii2r45ih3u1rq")
        #expect(account.slug == "/897362094")
        #expect(account.user.emailAddress == "chris@bluefenix.net")
    }

    @Test("boards.json decodes (array root)")
    func boards() throws {
        let data = try loadFixture("boards")
        let boards = try decoder.decode([FizzyBoard].self, from: data)
        #expect(boards.count == 1)
        #expect(boards[0].name == "Roadmap")
        #expect(boards[0].allAccess == true)
        #expect(boards[0].autoPostponePeriodInDays == 30)
    }

    @Test("columns.json decodes (array root, 3 columns)")
    func columns() throws {
        let data = try loadFixture("columns")
        let columns = try decoder.decode([FizzyColumn].self, from: data)
        #expect(columns.count == 3)
        #expect(columns.map(\.name) == ["Triage", "In Progress", "Review"])
        #expect(columns[1].color.name == "Lime")
    }

    @Test("cards.json decodes (list endpoint, no column field)")
    func cardsList() throws {
        let data = try loadFixture("cards")
        let cards = try decoder.decode([FizzyCard].self, from: data)
        #expect(cards.count == 3)
        #expect(cards[1].golden == true)
        #expect(cards[1].tags == ["urgent", "bug"])
        #expect(cards[1].column == nil)  // list endpoint omits column per Fizzy docs
        #expect(cards[2].imageURL?.absoluteString == "https://fizzy.bluefenix.net/uploads/cards/3.png")
    }

    @Test("card_single.json decodes (single endpoint with column + steps)")
    func cardSingle() throws {
        let data = try loadFixture("card_single")
        let card = try decoder.decode(FizzyCard.self, from: data)
        #expect(card.title == "First card")
        let column = try #require(card.column)
        #expect(column.name == "In Progress")
        let steps = try #require(card.steps)
        #expect(steps.count == 2)
        #expect(steps[1].completed == true)
    }
}

/// Bundle locator. Any class in the test target works; this is the convention.
private final class FixtureLocator {}
```

- [ ] **Step 2: Run failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyDTOTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyIdentity`, `FizzyBoard`, `FizzyColumn`, `FizzyCard` undefined.

- [ ] **Step 3: Implement `FizzyDTOs`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift`):

```swift
import Foundation

// Codable mirror of the Fizzy API wire shapes. Field names use Swift
// camelCase; JSON keys are mapped explicitly via `CodingKeys` rather than a
// global keyDecodingStrategy, because some Fizzy keys (`description_html`,
// `image_url`) don't survive the round-trip cleanly under .convertFromSnakeCase
// (the encoder writes `descriptionHtml` back, losing the original snake form).
// Explicit keys also document the wire contract in-source.

// MARK: - Identity

struct FizzyIdentity: Codable, Equatable {
    let accounts: [FizzyAccount]
}

struct FizzyAccount: Codable, Equatable {
    let id: String
    let name: String
    let slug: String              // e.g. "/897362094"
    let createdAt: Date
    let user: FizzyUser

    enum CodingKeys: String, CodingKey {
        case id, name, slug, user
        case createdAt = "created_at"
    }
}

struct FizzyUser: Codable, Equatable {
    let id: String
    let name: String
    let role: String
    let active: Bool
    let emailAddress: String
    let createdAt: Date
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, role, active, url
        case emailAddress = "email_address"
        case createdAt = "created_at"
    }
}

// MARK: - Board

struct FizzyBoard: Codable, Equatable {
    let id: String
    let name: String
    let allAccess: Bool
    let createdAt: Date
    let autoPostponePeriodInDays: Int
    let url: URL?
    let creator: FizzyUser

    enum CodingKeys: String, CodingKey {
        case id, name, url, creator
        case allAccess = "all_access"
        case createdAt = "created_at"
        case autoPostponePeriodInDays = "auto_postpone_period_in_days"
    }
}

// MARK: - Column

struct FizzyColumn: Codable, Equatable {
    let id: String
    let name: String
    let color: FizzyColor
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
    }
}

struct FizzyColor: Codable, Equatable {
    let name: String
    let value: String
}

// MARK: - Card

struct FizzyCard: Codable, Equatable {
    let id: String
    let number: Int
    let title: String
    let status: String
    let description: String?
    let descriptionHTML: String?
    let imageURL: URL?
    let hasAttachments: Bool
    let tags: [String]
    let closed: Bool?           // present only on single-card endpoint
    let golden: Bool
    let lastActiveAt: Date
    let createdAt: Date
    let url: URL?
    let column: FizzyColumn?    // present only on single-card endpoint per Fizzy docs
    let steps: [FizzyStep]?     // present only on single-card endpoint

    enum CodingKeys: String, CodingKey {
        case id, number, title, status, description, tags, closed, golden, url, column, steps
        case descriptionHTML = "description_html"
        case imageURL = "image_url"
        case hasAttachments = "has_attachments"
        case lastActiveAt = "last_active_at"
        case createdAt = "created_at"
    }
}

struct FizzyStep: Codable, Equatable {
    let id: String
    let content: String
    let completed: Bool
}

// MARK: - Card write payload

/// Body for POST /:account/boards/:board_id/cards and PUT /:account/cards/:n.
/// Wire shape is `{ "card": { ... } }` — see `FizzyCardWritePayload`.
struct FizzyCardWrite: Codable, Equatable {
    var title: String?
    var description: String?
    var status: String?         // "published" | "drafted"
    var tagIds: [String]?

    enum CodingKeys: String, CodingKey {
        case title, description, status
        case tagIds = "tag_ids"
    }
}

/// Wrapper: Fizzy expects `{ "card": <FizzyCardWrite> }` for create/update.
struct FizzyCardWritePayload: Codable, Equatable {
    let card: FizzyCardWrite
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyDTOTests \
  test 2>&1 | tail -15
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift \
        FenixKanbanTests/Services/Fizzy/FizzyDTOTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): Codable DTOs for Identity/Board/Column/Card

Explicit CodingKeys (vs. keyDecodingStrategy = .convertFromSnakeCase)
because Fizzy returns description_html / image_url / etc., and
.convertFromSnakeCase corrupts the round-trip on encode. The
single-card endpoint's column/steps/closed fields are optional —
the list endpoint omits them per Fizzy docs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `FizzyResponse` + `MockURLProtocol` test harness

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyResponse.swift`
- Create: `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift`

These are infrastructure — no behavior tests of their own; later client tasks consume them.

- [ ] **Step 1: Create `FizzyResponse`**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyResponse.swift`):

```swift
import Foundation

/// Wraps a decoded body + the ETag the server sent for it. `body == nil`
/// signals a 304 Not Modified — caller already has the latest version.
struct FizzyResponse<T> {
    let body: T?
    let etag: String?
}
```

- [ ] **Step 2: Create `MockURLProtocol`**

Content (write to `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift`):

```swift
import Foundation

/// In-process URL protocol that intercepts URLSession requests. Tests register
/// a handler closure that returns either a `(Data, HTTPURLResponse)` or throws.
///
/// Per-test setup:
///
///     let config = URLSessionConfiguration.ephemeral
///     config.protocolClasses = [MockURLProtocol.self]
///     let session = URLSession(configuration: config)
///     MockURLProtocol.handler = { req in (Data("hi".utf8), .ok(for: req)) }
final class MockURLProtocol: URLProtocol {

    /// Test sets this before issuing requests; cleared in tearDown.
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    /// Record of every request the SUT issued during the test, in order.
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension HTTPURLResponse {
    static func ok(for request: URLRequest, headers: [String: String] = [:]) -> HTTPURLResponse {
        response(for: request, status: 200, headers: headers)
    }

    static func notModified(for request: URLRequest, etag: String) -> HTTPURLResponse {
        response(for: request, status: 304, headers: ["ETag": etag])
    }

    static func response(for request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
```

- [ ] **Step 3: Regenerate + verify build**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyResponse.swift \
        FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
test(fizzy): MockURLProtocol harness + FizzyResponse wrapper

URLProtocol that lets the test set a request-handler closure and
inspect every issued request. HTTPURLResponse convenience inits
for the common .ok / .notModified shapes. FizzyResponse wraps
{ body, etag } so callers can short-circuit on 304s.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `FizzyClient` — init + auth header + account-slug interpolation (red → green)

**Files:**
- Create: `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`
- Create: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`

This task implements the constructor and the URL/header machinery. Subsequent tasks (6-9) extend the same file/test with more behaviors.

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`):

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyClient — auth + URL construction", .serialized)
struct FizzyClientAuthTests {

    init() {
        MockURLProtocol.reset()
    }

    private func makeClient(token: String = "test-token", slug: String = "897362094") -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: token,
            accountSlug: slug,
            urlSession: session
        )
    }

    @Test("GET attaches Bearer header + interpolates :account_slug into path")
    func authAndSlug() async throws {
        MockURLProtocol.handler = { req in
            let body = #"{"accounts":[]}"#.data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"abc\""]))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/897362094/boards")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("paths starting with /my are NOT account-scoped (Fizzy convention)")
    func myPathsBypassSlug() async throws {
        MockURLProtocol.handler = { req in
            let body = #"{"accounts":[]}"#.data(using: .utf8)!
            return (body, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/my/identity", as: FizzyIdentity.self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/my/identity")
    }
}
```

- [ ] **Step 2: Run failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientAuthTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyClient` undefined, `.get` method undefined.

- [ ] **Step 3: Implement `FizzyClient` (init + get only)**

Content (write to `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`):

```swift
import Foundation

/// HTTP client for the Fizzy API.
///
/// Adds `Authorization: Bearer <token>` and `Accept: application/json` to
/// every request. Interpolates `accountSlug` into paths unless the path begins
/// with `/my` (Fizzy's identity/profile namespace is not account-scoped).
final class FizzyClient: Sendable {

    private let baseURL: URL
    private let accessToken: String
    private let accountSlug: String
    private let urlSession: URLSession

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        baseURL: URL,
        accessToken: String,
        accountSlug: String,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accountSlug = accountSlug
        self.urlSession = urlSession
    }

    /// GET a JSON resource. Returns the decoded body — ETag handling lands in Task 6.
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let response = try await getWithETag(path, etag: nil, as: T.self)
        guard let body = response.body else {
            // 304 with no prior etag shouldn't happen — caller asked for fresh data.
            throw FizzyError.unexpectedStatus(304)
        }
        return body
    }

    /// GET with explicit ETag handling. Used by the sync engine; sends
    /// `If-None-Match` if `etag != nil`, returns `body == nil` on 304.
    /// Full implementation lands in Task 6 — for now it ignores etag.
    func getWithETag<T: Decodable & Sendable>(
        _ path: String,
        etag: String?,
        as: T.Type
    ) async throws -> FizzyResponse<T> {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 200:
            let decoded = try Self.decoder.decode(T.self, from: data)
            return FizzyResponse(body: decoded, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304:
            return FizzyResponse(body: nil, etag: http.value(forHTTPHeaderField: "ETag") ?? etag)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    // MARK: - URL construction

    /// Builds the absolute URL for a path. Paths starting with `/my` skip the
    /// account-slug prefix (Fizzy convention — `/my/identity` is not scoped).
    private func url(for path: String) -> URL {
        precondition(path.hasPrefix("/"), "FizzyClient paths must begin with `/`")
        let prefix = path.hasPrefix("/my") ? "" : "/\(accountSlug)"
        return baseURL.appending(path: "\(prefix)\(path)")
    }
}
```

The `urlSession` is captured by reference, which is allowed because `URLSession` is `Sendable`. `Self.decoder` is created once at class load.

- [ ] **Step 4: Run tests, verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientAuthTests \
  test 2>&1 | tail -15
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyClient.swift \
        FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): FizzyClient core — init, auth header, URL scoping

Bearer token on every request. /my/* paths bypass the account slug
per Fizzy's convention; everything else is /:account_slug/...
prefixed. ETag plumbing exists in the signature but is wired in
the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ETag round-trip (red → green)

**Files:**
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift` (append `FizzyClientETagTests` suite)

The ETag behavior is already in `FizzyClient.getWithETag` from Task 5 — this task just adds explicit tests that lock it in.

- [ ] **Step 1: Append failing tests**

Append to the bottom of `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — ETag", .serialized)
struct FizzyClientETagTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("getWithETag: nil etag → no If-None-Match header sent")
    func noEtagNoHeader() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v1\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: nil, as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(response.etag == "\"v1\"")
        #expect(response.body != nil)
    }

    @Test("getWithETag: 200 returns body and new etag")
    func twoHundredReturnsBodyAndEtag() async throws {
        MockURLProtocol.handler = { req in
            let body = "[]".data(using: .utf8)!
            return (body, .ok(for: req, headers: ["ETag": "\"v2\""]))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(response.body != nil)
        #expect(response.etag == "\"v2\"")
    }

    @Test("getWithETag: 304 returns nil body and preserves etag")
    func threeOhFourReturnsNilBody() async throws {
        MockURLProtocol.handler = { req in
            return (Data(), .notModified(for: req, etag: "\"v1\""))
        }

        let client = makeClient()
        let response: FizzyResponse<[FizzyBoard]> = try await client.getWithETag("/boards", etag: "\"v1\"", as: [FizzyBoard].self)

        #expect(response.body == nil)
        #expect(response.etag == "\"v1\"")
    }
}
```

- [ ] **Step 2: Run + verify they pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientETagTests \
  test 2>&1 | tail -15
```

Expected: 3 tests pass. (Implementation from Task 5 already supports this.)

- [ ] **Step 3: Commit**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
test(fizzy): lock ETag round-trip — 200 returns body+new etag, 304 returns nil body

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: POST + Location follow (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyClient.swift` (add `post`)
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift` (append `FizzyClientPostTests`)

Fizzy's POST returns `201 Created` with a `Location` header pointing at the new resource (no body). We do a follow-up GET to the Location to return the full decoded resource.

- [ ] **Step 1: Append failing tests**

Append to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — POST", .serialized)
struct FizzyClientPostTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("POST sends JSON body, follows Location header to GET the new resource")
    func postFollowsLocation() async throws {
        // Hand-rolled response for the second GET — pull from card_single fixture.
        let bundle = Bundle(for: FixtureLocator.self)
        let cardData = try Data(contentsOf: bundle.url(forResource: "card_single", withExtension: "json", subdirectory: "Fixtures/fizzy")!)

        MockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "POST":
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/boards/B1/cards")
                #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1"]
                )!
                return (Data(), response)
            case "GET":
                #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
                return (cardData, .ok(for: req))
            default:
                Issue.record("unexpected method: \(req.httpMethod ?? "nil")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "First card", description: "Hello, World!", status: nil, tagIds: nil))
        let created: FizzyCard = try await client.post("/boards/B1/cards", body: payload, as: FizzyCard.self)

        #expect(created.title == "First card")
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test("POST surfaces 422 with parsed validation errors")
    func postValidationError() async throws {
        MockURLProtocol.handler = { req in
            let body = #"{"errors":{"title":["can't be blank"]}}"#.data(using: .utf8)!
            return (body, .response(for: req, status: 422))
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "", description: nil, status: nil, tagIds: nil))

        await #expect(throws: FizzyError.validation(["title: can't be blank"])) {
            let _: FizzyCard = try await client.post("/boards/B1/cards", body: payload, as: FizzyCard.self)
        }
    }
}

private final class FixtureLocator {}
```

- [ ] **Step 2: Run + verify failure**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientPostTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyClient.post` undefined.

- [ ] **Step 3: Add `post` to `FizzyClient`**

In `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`, add a `post` method and an `encoder` property. Insert the encoder property near the existing `decoder`:

```swift
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
```

Then add this method below `getWithETag`:

```swift
    /// POST a JSON body. Fizzy returns 201 + Location header (no body); this
    /// method follows the Location with a GET and returns the decoded resource
    /// so callers get the new ID, ETag, and any server-generated fields in one
    /// call.
    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 201:
            guard let locationString = http.value(forHTTPHeaderField: "Location"),
                  let location = URL(string: locationString) else {
                throw FizzyError.unexpectedStatus(201)  // 201 without a Location is a bug
            }
            return try await followLocation(location, as: T.self)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    /// Internal: GET an absolute URL (skipping the slug interpolation) and
    /// decode the body. Used by `post` to follow `Location`.
    private func followLocation<T: Decodable & Sendable>(_ url: URL, as: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }
        guard http.statusCode == 200 else {
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
        return try Self.decoder.decode(T.self, from: data)
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientPostTests \
  test 2>&1 | tail -15
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyClient.swift \
        FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): POST with Location-follow + 422 surfacing

Fizzy's POST returns 201 + Location (no body). FizzyClient.post
follows the Location with a GET so callers get the new resource
in one call. 422 surfaces as FizzyError.validation with parsed
field-level messages.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: PUT (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`

Fizzy's PUT returns the updated card directly (200 + body), not 204.

- [ ] **Step 1: Append failing test**

Append to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — PUT", .serialized)
struct FizzyClientPutTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("PUT sends JSON body, returns updated resource")
    func putReturnsUpdated() async throws {
        let bundle = Bundle(for: PutFixtureLocator.self)
        let cardData = try Data(contentsOf: bundle.url(forResource: "card_single", withExtension: "json", subdirectory: "Fixtures/fizzy")!)

        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            return (cardData, .ok(for: req))
        }

        let client = makeClient()
        let payload = FizzyCardWritePayload(card: FizzyCardWrite(title: "Updated", description: nil, status: nil, tagIds: nil))
        let updated: FizzyCard = try await client.put("/cards/1", body: payload, as: FizzyCard.self)

        #expect(updated.id == "03f5vaeq985jlvwv3arl4srq2")
        #expect(MockURLProtocol.requests.count == 1)
    }
}

private final class PutFixtureLocator {}
```

- [ ] **Step 2: Run + verify failure**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientPutTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyClient.put` undefined.

- [ ] **Step 3: Add `put` to `FizzyClient`**

Add this method to `FizzyClient.swift`, below the `post` method:

```swift
    /// PUT a JSON body. Returns the updated resource (200 + body, not 204).
    func put<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 200:
            return try Self.decoder.decode(T.self, from: data)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientPutTests \
  test 2>&1 | tail -15
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyClient.swift \
        FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): PUT returning updated resource

Fizzy's PUT returns the updated card directly (200 + body), unlike
POST which returns 201 + Location.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: DELETE (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`

- [ ] **Step 1: Append failing test**

Append to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — DELETE", .serialized)
struct FizzyClientDeleteTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("DELETE succeeds on 204")
    func deleteSucceeds() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "DELETE")
            #expect(req.url?.absoluteString == "https://fizzy.bluefenix.net/ACCT/cards/1")
            return (Data(), .response(for: req, status: 204))
        }

        let client = makeClient()
        try await client.delete("/cards/1")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test("DELETE surfaces 404 as FizzyError.notFound")
    func deleteNotFound() async throws {
        MockURLProtocol.handler = { req in
            return (Data(), .response(for: req, status: 404))
        }

        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            try await client.delete("/cards/999")
        }
    }
}
```

- [ ] **Step 2: Run + verify failure**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientDeleteTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyClient.delete` undefined.

- [ ] **Step 3: Add `delete` to `FizzyClient`**

Add this method to `FizzyClient.swift`, below `put`:

```swift
    /// DELETE a resource. Returns on 204; throws on any other status.
    func delete(_ path: String) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 204:
            return
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }
```

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientDeleteTests \
  test 2>&1 | tail -15
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyClient.swift \
        FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): DELETE for cards (204 success, propagates 404)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Error mapping coverage (red → green)

**Files:**
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift` (append `FizzyClientErrorTests`)

The error mapping is already in `FizzyClient` from the GET path — this task adds explicit per-status tests so a future refactor that breaks one of them gets caught.

- [ ] **Step 1: Append failing tests**

Append to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — HTTP error mapping", .serialized)
struct FizzyClientErrorTests {

    init() { MockURLProtocol.reset() }

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session
        )
    }

    @Test("401 → .unauthorized")
    func unauthorized() async throws {
        MockURLProtocol.handler = { req in (Data(), .response(for: req, status: 401)) }
        let client = makeClient()
        await #expect(throws: FizzyError.unauthorized) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("403 → .forbidden")
    func forbidden() async throws {
        MockURLProtocol.handler = { req in (Data(), .response(for: req, status: 403)) }
        let client = makeClient()
        await #expect(throws: FizzyError.forbidden) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("404 → .notFound")
    func notFound() async throws {
        MockURLProtocol.handler = { req in (Data(), .response(for: req, status: 404)) }
        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            _ = try await client.get("/boards/missing", as: FizzyBoard.self)
        }
    }

    @Test("500 → .server(500)")
    func server() async throws {
        MockURLProtocol.handler = { req in (Data(), .response(for: req, status: 500)) }
        let client = makeClient()
        await #expect(throws: FizzyError.server(statusCode: 500)) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }

    @Test("429 → .rateLimited honors Retry-After")
    func rateLimited() async throws {
        MockURLProtocol.handler = { req in
            (Data(), .response(for: req, status: 429, headers: ["Retry-After": "30"]))
        }
        let client = makeClient()
        await #expect(throws: FizzyError.rateLimited(retryAfter: 30)) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
    }
}
```

- [ ] **Step 2: Run + verify pass** (no implementation needed — already covered)

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientErrorTests \
  test 2>&1 | tail -15
```

Expected: 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
test(fizzy): per-status error mapping coverage for GET path

Locks in 401/403/404/429/500 → FizzyError mappings so future
refactors of the dispatch switch get caught.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Retry on transient failures (red → green)

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`
- Modify: `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift` (append `FizzyClientRetryTests`)

Per spec §6, transient network failures (URLError) are retried 3× with exponential backoff (1s/2s/4s). 4xx errors are NOT retried. To keep tests fast, retries use a `Clock` parameter so we can inject `ImmediateClock`.

- [ ] **Step 1: Append failing tests**

Append to `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`:

```swift
@Suite("FizzyClient — retry", .serialized)
struct FizzyClientRetryTests {

    init() { MockURLProtocol.reset() }

    private func makeClient(clock: any Clock<Duration> = ImmediateClock()) -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: session,
            clock: clock
        )
    }

    @Test("transient network error retries up to 3 times then succeeds")
    func transientThenSucceeds() async throws {
        var attempt = 0
        MockURLProtocol.handler = { req in
            attempt += 1
            if attempt < 3 {
                throw URLError(.networkConnectionLost)
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(attempt == 3)
    }

    @Test("transient network error gives up after 3 retries and surfaces .network")
    func transientGivesUp() async throws {
        var attempt = 0
        MockURLProtocol.handler = { req in
            attempt += 1
            throw URLError(.networkConnectionLost)
        }

        let client = makeClient()
        do {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
            Issue.record("expected throw")
        } catch let error as FizzyError {
            // After initial + 3 retries = 4 attempts total
            #expect(attempt == 4)
            if case .network = error {
                // ok
            } else {
                Issue.record("expected .network, got \(error)")
            }
        }
    }

    @Test("4xx is not retried")
    func clientErrorNotRetried() async throws {
        var attempt = 0
        MockURLProtocol.handler = { req in
            attempt += 1
            return (Data(), .response(for: req, status: 404))
        }

        let client = makeClient()
        await #expect(throws: FizzyError.notFound) {
            _ = try await client.get("/boards", as: [FizzyBoard].self)
        }
        #expect(attempt == 1)
    }

    @Test("5xx IS retried")
    func serverErrorRetried() async throws {
        var attempt = 0
        MockURLProtocol.handler = { req in
            attempt += 1
            if attempt < 3 {
                return (Data(), .response(for: req, status: 503))
            }
            return ("[]".data(using: .utf8)!, .ok(for: req))
        }

        let client = makeClient()
        _ = try await client.get("/boards", as: [FizzyBoard].self)
        #expect(attempt == 3)
    }
}
```

- [ ] **Step 2: Run + verify failure**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientRetryTests \
  test 2>&1 | tail -15
```

Expected: build fails — `FizzyClient` init signature missing `clock`, retry logic absent.

- [ ] **Step 3: Add clock + retry to `FizzyClient`**

Update `FizzyClient.swift`. First, change the init signature and add the property:

Replace this property block:

```swift
    private let baseURL: URL
    private let accessToken: String
    private let accountSlug: String
    private let urlSession: URLSession
```

With:

```swift
    private let baseURL: URL
    private let accessToken: String
    private let accountSlug: String
    private let urlSession: URLSession
    private let clock: any Clock<Duration>
```

Replace this init:

```swift
    init(
        baseURL: URL,
        accessToken: String,
        accountSlug: String,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accountSlug = accountSlug
        self.urlSession = urlSession
    }
```

With:

```swift
    init(
        baseURL: URL,
        accessToken: String,
        accountSlug: String,
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accountSlug = accountSlug
        self.urlSession = urlSession
        self.clock = clock
    }
```

Now add this private retry helper, and use it everywhere `urlSession.data(for:)` is currently called directly:

```swift
    /// Performs the request with up to 3 retries on transient failures (network
    /// errors or 5xx responses). 4xx propagates immediately. Backoff: 1s, 2s, 4s.
    private func performWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

        for attempt in 0...delays.count {
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FizzyError.unexpectedStatus(0)
                }
                if (500...599).contains(http.statusCode), attempt < delays.count {
                    try await clock.sleep(for: delays[attempt])
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                if attempt < delays.count {
                    try await clock.sleep(for: delays[attempt])
                    continue
                }
                throw FizzyError.network(error)
            }
        }
        // Unreachable: the loop always returns or throws by attempt 3.
        throw FizzyError.unexpectedStatus(0)
    }
```

Then replace the four occurrences of `try await urlSession.data(for: request)` (in `getWithETag`, `post`, `followLocation`, `put`, `delete`) with `try await performWithRetry(request)`. The destructuring stays the same: `let (data, http) = try await performWithRetry(request)` — but you'll also need to remove the `guard let http = response as? HTTPURLResponse` lines that follow, since `performWithRetry` already returns a typed `HTTPURLResponse`.

For example, change this in `getWithETag`:

```swift
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
```

To this:

```swift
        let (data, http) = try await performWithRetry(request)

        switch http.statusCode {
```

Do the same substitution in `post`, `put`, `delete`, and `followLocation`.

- [ ] **Step 4: Run + verify pass**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyClientRetryTests \
  test 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 5: Run the full Fizzy suite to confirm nothing regressed**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/FizzyErrorTests \
  -only-testing:FenixKanbanTests/FizzyDTOTests \
  -only-testing:FenixKanbanTests/FizzyClientAuthTests \
  -only-testing:FenixKanbanTests/FizzyClientETagTests \
  -only-testing:FenixKanbanTests/FizzyClientPostTests \
  -only-testing:FenixKanbanTests/FizzyClientPutTests \
  -only-testing:FenixKanbanTests/FizzyClientDeleteTests \
  -only-testing:FenixKanbanTests/FizzyClientErrorTests \
  -only-testing:FenixKanbanTests/FizzyClientRetryTests \
  test 2>&1 | grep -E "Test run|TEST" | tail -3
```

Expected: ~28 Fizzy tests pass overall.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzyClient.swift \
        FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
git commit -m "$(cat <<'EOF'
feat(fizzy): exponential-backoff retry on transient failures

URLError + 5xx are retried up to 3 times (1s/2s/4s). 4xx propagates
immediately. Injected Clock parameter keeps unit tests instant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Document in `TDD_IMPLEMENTATION_STATUS.md`

**File:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` (append a new section)

- [ ] **Step 1: Append the entry**

Append to the end of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown

### Fizzy Integration — Phase 1: Client + DTOs + Error ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- Wrote tests for `FizzyError` (status → error mapping; 422 body parse; 429 Retry-After).
- Wrote DTO decode tests against hand-transcribed fixtures.
- Wrote `FizzyClient` tests for auth header, `:account_slug` interpolation, ETag round-trip, POST + Location-follow, PUT, DELETE, per-status error mapping, and transient retry/backoff.
- All ~28 tests verified failing before implementation.

**🟢 Green Phase:**
- `FenixKanban/Core/Services/Fizzy/FizzyError.swift` — typed errors with 422 body parsing and 429 Retry-After handling.
- `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift` — Codable mirrors of Identity/Account/User/Board/Column/Card/Step/CardWrite wire shapes.
- `FenixKanban/Core/Services/Fizzy/FizzyResponse.swift` — `{ body, etag }` wrapper.
- `FenixKanban/Core/Services/Fizzy/FizzyClient.swift` — HTTP wrapper with Bearer auth, `:account_slug` path interpolation (`/my/*` bypasses), GET with ETag, POST + Location-follow, PUT, DELETE, exponential-backoff retry, injected `Clock` for testability.
- `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift` — in-process URL intercept harness; zero live network in CI.
- `FenixKanbanTests/Fixtures/fizzy/` — hand-transcribed sample payloads.

**🔵 Refactor Phase:**
- `project.yml` `resources:` block packs fixtures into the test bundle.
- Retry path consolidated into a single `performWithRetry` helper called by every verb.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-1-client.md`

**Test Coverage:** ~28 new tests; full suite target after Phase 1: ~159/159.

**What ships:** A standalone Fizzy HTTP client, fully testable against a mock URL protocol, with no app wiring yet. Phases 2-6 layer on auth state, board mapping, CoreData migration, sync engine, UI, and timer/badges.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 1 (client + DTOs + error) in status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Final verification (NO push)

The user has requested holding all pushes to origin. This task confirms the branch is ready locally but stops short of `git push`.

- [ ] **Step 1: Run the full test suite to confirm no regressions**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: `Test run with ~159 tests in ~32 suites passed`. If anything fails, diagnose before continuing.

- [ ] **Step 2: Clean build of the macOS target**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`, no warnings introduced by Phase 1 changes.

- [ ] **Step 3: Verify final branch state**

```bash
git log --oneline -15
git status -sb
```

Expected: 12 new commits (one per task 1-11 with multi-step ones rolled up to a single commit, plus the status-doc commit), clean working tree, branch ahead of origin/develop. **Do NOT run `git push`.**

- [ ] **Step 4: Report ready-for-PR state**

Tell the user the phase is ready to ship and what the PR title/body should be when they're ready to push. Suggested title:

> `feat(fizzy): Phase 1 — HTTP client, DTOs, error types (no app wiring)`

Suggested body skeleton (do not run `gh pr create`):

```markdown
## Summary
- New `FizzyClient` for talking to fizzy.bluefenix.net (Phase 1 of 6).
- Bearer auth, account-slug path interpolation, ETag round-trip, POST + Location-follow, PUT, DELETE.
- Exponential-backoff retry on transient failures (URLError + 5xx); 4xx surfaces immediately.
- ~28 new tests; full suite ~159/159.
- Zero app wiring — Phases 2-6 layer on auth state, board mapping, CoreData migration, sync engine, UI, and timer/badges.

## Test plan
- [x] Build clean on iOS Simulator + macOS.
- [x] ~28 new Fizzy tests pass; full suite green.
- [x] No live network — all client tests run against `MockURLProtocol`.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-1-client.md`
```

---

## Success criteria recap

- [ ] All Phase 1 files exist with the contents specified.
- [ ] ~28 new Fizzy tests pass; full suite passes.
- [ ] iOS Simulator + macOS targets build clean with no warnings.
- [ ] Zero live network — every test uses `MockURLProtocol`.
- [ ] `FizzyClient` API surface: `init`, `get(_:as:)`, `getWithETag(_:etag:as:)`, `post(_:body:as:)`, `put(_:body:as:)`, `delete(_:)`.
- [ ] All five public verbs go through `performWithRetry` with exponential backoff (1s/2s/4s) on URLError or 5xx; 4xx propagates immediately.
- [ ] 422 body parses into `FizzyError.validation([String])`; 429 honors Retry-After (default 60s).
- [ ] Paths starting with `/my` skip the account-slug prefix.
- [ ] `TDD_IMPLEMENTATION_STATUS.md` updated.
- [ ] Branch is local-only — no push to origin.
