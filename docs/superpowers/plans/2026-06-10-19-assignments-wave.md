# Issue #19 Wave 2: Assignments (avatar row + assignment toggling) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paired cards show who's assigned (initials-avatar row in card detail) and let the user toggle assignments against Fizzy.

**Architecture:** Assignees ride the **column-cards list payload** (`assignees: [FizzyUser]` per card — NOT in the single-card doc), so the sync pull captures them and persists a minimal JSON blob on `Card` (CoreData v7, one additive optional Binary attribute → trivial lightweight migration). Display reads the blob; toggling POSTs `/cards/:n/assignments` (existing client method) with optimistic update + state-recheck revert, mirroring `toggleLabel`. Remote-authoritative on pull, like tags. **Captain's rulings:** JSON blob storage (no Assignee entity); initials circles only (avatar URLs need the bearer token — AsyncImage can't send it).

**Tech Stack:** Swift 6, SwiftUI, CoreData (lightweight migration), Swift Testing (`@Test`/`#expect`/`#require`), MockURLProtocol.

**Conventions (apply to every task):**
- Repo practice: commit directly to `develop`. When RED is a compile error, test+impl share ONE commit with the bend noted in the body.
- Tests run on the PINNED simulator only: `xcrun simctl boot 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB 2>/dev/null; xcrun simctl bootstatus 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB` then `xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB'`. "preflight checks/Busy" is sim noise. SourceKit editor diagnostics are stale-index noise; only xcodebuild output counts.
- macOS check after impl tasks: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build` — zero warnings.
- New files need `make generate` (xcodegen) to join targets. `.xccurrentversion` updates happen BEFORE `make generate`.
- Mock failures use **422, never 500** (client retries 5xx 3×).
- Mock response helpers are `HTTPURLResponse` extensions — spell `.ok(for: request)` and `.response(for: request, status: 422)` (implicit member syntax), NOT `MockURLProtocol.ok(...)`.
- `TDD_IMPLEMENTATION_STATUS.md` (repo root) gains an entry with every code commit. Next entry is **#26**, heading format `### 26. Issue #19 Wave 2 Task 1 — ...`. Read the file tail first to match format.
- Baseline: **348 tests / 71 suites** green.

---

### Task 1: DTOs decode assignees + avatar_url

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift` (FizzyUser ~line 29, FizzyCard ~line 107)
- Test: `FenixKanbanTests/Services/Fizzy/FizzyClientBoardsTests.swift`

- [ ] **Step 1: Write the failing test**

`FizzyClientBoardsTests.swift` already consumes `Fixtures/fizzy/column_cards_doc.json` — read the file first and mirror its existing fixture/client helpers (`loadFixture`, `makeClient` or equivalents) exactly. Add:

```swift
@Test("cards decode assignees from the column cards doc (fixture verbatim)")
func cardsDecodeAssignees() async throws {
    MockURLProtocol.reset()
    defer { MockURLProtocol.reset() }
    let data = try loadFixture("column_cards_doc")
    MockURLProtocol.handler = { request in (data, .ok(for: request)) }

    let cards = try await makeClient().cards(boardID: "B1", columnID: "C1")

    let assignees = try #require(cards.first?.assignees)
    #expect(assignees.count == 1)
    #expect(assignees.first?.name == "David Heinemeier Hansson")
    #expect(assignees.first?.id == "03f5v9zjw7pz8717a4no1h8a7")
    #expect(assignees.first?.avatarURL != nil)
}
```

(The fixture's first card carries exactly one assignee with `avatar_url` set — wire-shape rule: the fixture is served verbatim.)

- [ ] **Step 2: Verify RED**

Compile error (`assignees`/`avatarURL` don't exist) — right reason. Test+impl share one commit, noted in the body.

- [ ] **Step 3: Implement the DTO additions**

In `FizzyUser`, add the property and CodingKey (CodingKeys are explicit in this file — NO `.convertFromSnakeCase`):

```swift
struct FizzyUser: Codable, Equatable {
    let id: String
    let name: String
    let role: String
    let active: Bool
    let emailAddress: String
    let createdAt: Date
    let url: URL?
    let avatarURL: URL?          // absent on /my/identity payloads — optional

    enum CodingKeys: String, CodingKey {
        case id, name, role, active, url
        case emailAddress = "email_address"
        case createdAt = "created_at"
        case avatarURL = "avatar_url"
    }
}
```

In `FizzyCard`, add (list-endpoint-only field, like `closed` is detail-only):

```swift
    let assignees: [FizzyUser]?  // present only on the column-cards list endpoint
```

and `case assignees` in the first CodingKeys line (it's a 1:1 key, joins `id, number, title, ...`).

**Check all `FizzyUser(...)` / `FizzyCard(...)` memberwise-init call sites** (grep tests + app) and add `avatarURL: nil` / `assignees: nil` where needed.

- [ ] **Step 4: Run the test file, then the full suite**

Expected: new test passes; full suite 349 tests / 71 suites green; macOS build clean.

- [ ] **Step 5: TDD entry #26 + commit**

```bash
git add -A
git commit -m "feat(19): decode card assignees + user avatar_url from wire

Test+impl in one commit: RED state was a compile error (new DTO fields)."
```

---

### Task 2: CoreData v7 — additive `assigneesData` blob + `CardAssignee`

**Files:**
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 7.xcdatamodel/contents` (copy of v6 + one attribute)
- Modify: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`
- Create: `FenixKanban/Core/Persistence/CardAssignee.swift`
- Test: `FenixKanbanTests/Persistence/CoreDataMigrationV7Tests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CoreDataMigrationV7Tests.swift`. Mirror `CoreDataMigrationV6Tests.swift`'s model-loading helpers exactly (class-stripped models loaded from the .momd via `Bundle(for: PluginRegistry.self)`) — read that file first and reuse its approach for locating versioned models.

```swift
import Testing
import CoreData
@testable import FenixKanban

@Suite("CoreData v6→v7 Migration")
struct CoreDataMigrationV7Tests {

    // Reuse the same model-loading helper pattern as CoreDataMigrationV6Tests
    // (load "FenixKanban 6" and "FenixKanban 7" from the compiled .momd,
    // stripping representedClassName to avoid dual-registration warnings).

    @Test("v7 Card gains optional binary assigneesData; rest unchanged")
    func v7ModelShape() throws {
        let v7 = try loadModel(named: "FenixKanban 7")
        let card = try #require(v7.entitiesByName["Card"])
        let attr = try #require(card.attributesByName["assigneesData"])
        #expect(attr.attributeType == .binaryDataAttributeType)
        #expect(attr.isOptional)
        // labels relationship untouched
        let labels = try #require(card.relationshipsByName["labels"])
        #expect(labels.isToMany)
    }

    @Test("lightweight mapping v6→v7 is inferable (additive only)")
    func v6ToV7Inferable() throws {
        let v6 = try loadModel(named: "FenixKanban 6")
        let v7 = try loadModel(named: "FenixKanban 7")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v6, destinationModel: v7)
        #expect(!mapping.entityMappings.isEmpty)
    }
}
```

(No on-disk data-survival test this time — v6 proved the heavy machinery; v7 is additive-only, where inference cannot drop data.)

- [ ] **Step 2: Verify RED**

Fails: "FenixKanban 7" model doesn't exist.

- [ ] **Step 3: Create the v7 model**

```bash
cd "FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld"
cp -R "FenixKanban 6.xcdatamodel" "FenixKanban 7.xcdatamodel"
```

In `FenixKanban 7.xcdatamodel/contents`, inside `<entity name="Card" ...>`, add after the `cardDescription` attribute line:

```xml
<attribute name="assigneesData" optional="YES" attributeType="Binary"/>
```

Update `.xccurrentversion`: `<string>FenixKanban 6.xcdatamodel</string>` → `<string>FenixKanban 7.xcdatamodel</string>`. THEN `make generate`.

- [ ] **Step 4: Create `CardAssignee.swift`**

```swift
import Foundation
import CoreData

/// Minimal persisted shape for a card assignee. Assignees arrive embedded in
/// the column-cards pull payload and are remote-authoritative (like tags) —
/// stored as a JSON blob on Card (Captain's ruling on #19 wave 2: no
/// dedicated entity; id + name is all the initials-avatar row needs).
struct CardAssignee: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

extension Card {
    /// JSON-blob accessor over `assigneesData`. Empty array when unset or
    /// undecodable (never throws into the UI).
    var assignees: [CardAssignee] {
        get {
            guard let data = assigneesData else { return [] }
            return (try? JSONDecoder().decode([CardAssignee].self, from: data)) ?? []
        }
        set {
            assigneesData = try? JSONEncoder().encode(newValue)
        }
    }
}
```

- [ ] **Step 5: Run tests + both builds, TDD entry #27, commit**

Expected: 351 tests / 72 suites green; both platforms clean.

```bash
git add -A
git commit -m "feat(19): CoreData v7 — assigneesData blob on Card + CardAssignee

Additive-only lightweight migration (one optional Binary attribute).
Test+impl in one commit: RED was a missing model version."
```

---

### Task 3: Sync pull maps assignees → blob

**Files:**
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` (applyRemote, ~line 686)
- Test: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Mirror `pullMapsAllTags` (same `Harness`, same handler shape). The cards JSON must include the wire-shape assignee object (all real fields, per `column_cards_doc.json`):

```swift
@Test("pull: card assignees land in the persisted blob")
func pullMapsAssignees() async throws {
    let h = Harness()
    defer { h.tearDown() }

    let columnsJSON = """
    [{"id":"FC1","name":"Triage","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
    """
    let cardsJSON = """
    [{"id":"fzA1","number":21,"title":"Assigned","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/21","assignees":[{"id":"u1","name":"Ada Lovelace","role":"member","active":true,"email_address":"ada@example.com","created_at":"2025-12-05T19:36:35.401Z","url":"https://fizzy.bluefenix.net/ACCT/users/u1","avatar_url":"https://fizzy.bluefenix.net/ACCT/users/u1/avatar"}],"has_more_assignees":false}]
    """
    MockURLProtocol.handler = { req in
        switch (req.httpMethod, req.url?.path) {
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

    let card = h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 21 }
    #expect(card?.assignees == [CardAssignee(id: "u1", name: "Ada Lovelace")])
}

@Test("pull: empty assignees array clears the blob; absent key leaves it alone")
func pullClearsOrPreservesAssignees() async throws {
    let h = Harness()
    defer { h.tearDown() }
    // Pre-seed a paired local card with an assignee blob, fizzyUpdatedAt ==
    // modifiedAt == older-than-remote so the LWW pull branch runs
    // (same seeding approach as pullClearsRemovedTags — mirror it).
    // Round 1: remote card JSON with "assignees":[] → expect card.assignees == [].
    // Round 2: remote card JSON with NO assignees key (single-card-doc shape)
    //           and a newer last_active_at → expect blob unchanged from round 1.
}
```

Write the second test fully by mirroring `pullClearsRemovedTags`'s seeding (read it first); the assertions are exactly the two comments above.

- [ ] **Step 2: Verify RED** — `card?.assignees` is empty (engine never writes the blob). Right reason: assertion failure, not compile error. Commit the failing tests:

```bash
git add FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "test(19): sync pull maps assignees to Card blob (RED)"
```

- [ ] **Step 3: Implement in applyRemote**

After the tags→labels block in `applyRemote(_:to:)`:

```swift
        // Assignees ride the column-cards list payload (not the single-card
        // doc). Remote-authoritative on pull, like tags. A nil array means
        // the payload doesn't carry the field — leave the local blob alone.
        if let remoteAssignees = remote.assignees {
            card.assignees = remoteAssignees.map { CardAssignee(id: $0.id, name: $0.name) }
        }
```

- [ ] **Step 4: Run full suite** — expected 353 tests / 72 suites green; macOS clean.

- [ ] **Step 5: TDD entry #28 + commit**

```bash
git add -A
git commit -m "feat(19): sync pull persists card assignees (GREEN)"
```

---

### Task 4: Assignment toggling from the detail view model

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanban/Core/Repositories/CardRepository.swift`
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

New suite in `CardDetailViewModelTests.swift`, mirroring `CardDetailViewModelTagPushTests`'s construction (paired card `fizzyNumber = 7`, MockURLProtocol-backed client) — read that suite first and copy its init/teardown:

```swift
@Suite("CardDetailViewModel assignment push", .serialized)
@MainActor
struct CardDetailViewModelAssignmentPushTests {
    // init: same harness as CardDetailViewModelTagPushTests (paired card
    // fizzyNumber=7, fizzyID="fz7", client via MockURLProtocol).

    @Test("toggle POSTs /cards/7/assignments with assignee_id and updates the blob")
    func togglePostsAssignment() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(viewModel.assignees.map(\.id) == ["u9"])
        #expect(card.assignees.map(\.id) == ["u9"])
        let post = MockURLProtocol.requests.first { $0.httpMethod == "POST" }
        #expect(post?.url?.path.hasSuffix("/cards/7/assignments") == true)
    }

    @Test("toggle on an already-assigned user removes them")
    func toggleRemovesAssigned() async throws {
        MockURLProtocol.handler = { request in (Data(), .response(for: request, status: 204)) }
        card.assignees = [CardAssignee(id: "u9", name: "Grace Hopper")]
        // re-create viewModel AFTER seeding so init picks up the blob
        // (construct the same way the suite init does)
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(viewModel.assignees.isEmpty)
        #expect(card.assignees.isEmpty)
    }

    @Test("failed POST (422) reverts the optimistic change and surfaces an error")
    func failedToggleReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
        }
        let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                             emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)

        await viewModel.toggleAssignment(user)

        #expect(viewModel.assignees.isEmpty)
        #expect(card.assignees.isEmpty)
        #expect(viewModel.errorMessage != nil)
    }
}
```

And in the original (unpaired, no-client) suite:

```swift
@Test("unpaired card: toggleAssignment is a no-op with zero network")
func unpairedToggleAssignmentNoOp() async throws {
    MockURLProtocol.reset()
    defer { MockURLProtocol.reset() }
    let user = FizzyUser(id: "u9", name: "Grace Hopper", role: "member", active: true,
                         emailAddress: "g@example.com", createdAt: .now, url: nil, avatarURL: nil)
    await viewModel.toggleAssignment(user)
    #expect(viewModel.assignees.isEmpty)
    #expect(MockURLProtocol.requests.isEmpty)
}
```

- [ ] **Step 2: Verify RED** — compile error (`toggleAssignment`/`assignees` don't exist). One commit, bend noted.

- [ ] **Step 3: Implement**

`CardRepository.swift` — add:

```swift
    func updateAssignees(for card: Card, to assignees: [CardAssignee]) {
        card.assignees = assignees
        card.modifiedAt = Date()
        save()
    }
```

`CardDetailViewModel.swift` — change `private let fizzyClient` to `let fizzyClient` (the picker sheet needs it), and add:

```swift
    @Published var assignees: [CardAssignee]
    @Published var showAssigneePicker = false
```

in `init` (after `self.selectedLabels = ...`): `self.assignees = card.assignees`

```swift
    /// Assignments are fizzy-only: the row renders (and toggles run) only
    /// for paired cards with a live client (issue #19 wave 2).
    var canEditAssignments: Bool {
        card.fizzyNumber > 0 && fizzyClient != nil
    }

    /// Toggles a user's assignment: optimistic blob update, POST toggle,
    /// state-recheck revert on failure (same pattern as `toggleLabel` —
    /// last writer wins locally; the next pull reconciles the server).
    func toggleAssignment(_ user: FizzyUser) async {
        guard card.fizzyNumber > 0, let client = fizzyClient else { return }
        let wasAssigned = assignees.contains { $0.id == user.id }
        if wasAssigned {
            assignees.removeAll { $0.id == user.id }
        } else {
            assignees.append(CardAssignee(id: user.id, name: user.name))
        }
        cardRepository.updateAssignees(for: card, to: assignees)

        do {
            try await client.toggleCardAssignment(number: Int(card.fizzyNumber), assigneeID: user.id)
        } catch {
            // Revert only if no later toggle changed this user's state while
            // the POST was in flight.
            if assignees.contains(where: { $0.id == user.id }) != wasAssigned {
                if wasAssigned {
                    assignees.append(CardAssignee(id: user.id, name: user.name))
                } else {
                    assignees.removeAll { $0.id == user.id }
                }
                cardRepository.updateAssignees(for: card, to: assignees)
            }
            errorMessage = "Couldn't update assignment for \(user.name) on Fizzy."
        }
    }
```

- [ ] **Step 4: Run full suite** — expected 357 tests / 73 suites green; macOS clean.

- [ ] **Step 5: TDD entry #29 + commit**

```bash
git add -A
git commit -m "feat(19): assignment toggles push to Fizzy, optimistic w/ revert

Test+impl in one commit: RED state was a compile error (new members)."
```

---

### Task 5: Avatar row + assignee picker UI

**Files:**
- Create: `FenixKanban/Components/InitialsAvatar.swift`
- Create: `FenixKanban/Features/Card/AssigneePickerView.swift`
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`
- Test: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests (gating exposure)**

In the assignment-push suite: `#expect(viewModel.canEditAssignments == true)` as a new test `pairedCardCanEditAssignments`. In the original (unpaired) suite: `#expect(viewModel.canEditAssignments == false)` as `unpairedCardCannotEditAssignments`. (If Task 4 already shipped `canEditAssignments`, these compile and PASS immediately — that's fine; they lock the gate. Note it in the commit body instead of claiming RED.)

- [ ] **Step 2: Create `InitialsAvatar.swift`**

```swift
import SwiftUI

/// Colored initials circle for a person. Initials-only by Captain's ruling
/// (#19 wave 2): Fizzy avatar URLs require the bearer token, which
/// AsyncImage can't send. Color is FNV-derived from the name (same
/// determinism as auto-created label colors).
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 28

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Circle()
            .fill(Color(hex: FizzySyncMapping.labelColorHex(forName: name)))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(name)
    }
}
```

(`Color(hex:)` already exists — used by LabelPickerView et al. No `.background` anywhere — Liquid Glass rule.)

- [ ] **Step 3: Create `AssigneePickerView.swift`**

Mirror `LabelPickerView.swift`'s structure (read it first — Done button, no dismiss-on-tap, checkmarks). Users are fetched live from `GET /users` (online-only):

```swift
import SwiftUI

/// Multi-select assignee picker for a fizzy-paired card (issue #19 wave 2).
/// The user list is fetched live from `GET /users`; assignment state is the
/// card's persisted blob, toggled through the parent view model. Local
/// checkmark state flips immediately (same optimistic feel as the toggle).
struct AssigneePickerView: View {
    let client: FizzyClient
    let onToggle: (FizzyUser) -> Void
    @State private var assignedIDs: Set<String>
    @State private var users: [FizzyUser] = []
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    init(client: FizzyClient, assignedIDs: Set<String>, onToggle: @escaping (FizzyUser) -> Void) {
        self.client = client
        self.onToggle = onToggle
        self._assignedIDs = State(initialValue: assignedIDs)
    }

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView("Couldn't load users", systemImage: "person.2.slash")
                } else if users.isEmpty {
                    ProgressView()
                } else {
                    List(users, id: \.id) { user in
                        Button {
                            if assignedIDs.contains(user.id) {
                                assignedIDs.remove(user.id)
                            } else {
                                assignedIDs.insert(user.id)
                            }
                            onToggle(user)
                        } label: {
                            HStack(spacing: 10) {
                                InitialsAvatar(name: user.name)
                                Text(user.name)
                                Spacer()
                                if assignedIDs.contains(user.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(user.name)
                        .accessibilityValue(assignedIDs.contains(user.id) ? "Assigned" : "Not assigned")
                    }
                }
            }
            .navigationTitle("Assignees")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do { users = try await client.users().filter(\.active) }
                catch { loadFailed = true }
            }
        }
    }
}
```

- [ ] **Step 4: Render the row in `CardDetailView`**

After the Labels HStack (the one ending with "Remove all labels"), add:

```swift
                // Assignees (fizzy-paired cards only — issue #19 wave 2)
                if viewModel.canEditAssignments {
                    HStack {
                        Text("Assignees")
                        Spacer()
                        if viewModel.assignees.isEmpty {
                            Button("Assign") { viewModel.showAssigneePicker = true }
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: -6) {
                                ForEach(viewModel.assignees) { assignee in
                                    InitialsAvatar(name: assignee.name)
                                }
                            }
                            .onTapGesture { viewModel.showAssigneePicker = true }
                            .accessibilityLabel("Assignees: \(viewModel.assignees.map(\.name).joined(separator: ", "))")
                            .accessibilityHint("Opens the assignee picker.")
                        }
                    }
                }
```

Next to the existing label-picker `.sheet`, add:

```swift
        .sheet(isPresented: $viewModel.showAssigneePicker) {
            if let client = viewModel.fizzyClient {
                AssigneePickerView(
                    client: client,
                    assignedIDs: Set(viewModel.assignees.map(\.id))
                ) { user in
                    Task { await viewModel.toggleAssignment(user) }
                }
            }
        }
```

(Toggle failures surface through the existing "Sync Error" alert — `toggleAssignment` writes `viewModel.errorMessage`.)

- [ ] **Step 5: `make generate`, run full suite + macOS build**

Expected: 359 tests / 73 suites green; macOS BUILD SUCCEEDED, zero warnings.

- [ ] **Step 6: TDD entry #30 + commit**

```bash
git add -A
git commit -m "feat(19): assignee avatar row + picker in card detail (GREEN)"
```

---

### Task 6: Finalize — full verification, status doc, report

- [ ] **Step 1: Full verification pass** (pinned sim test run + iOS and macOS builds). Expected: every suite green (~359 tests / 73 suites), zero warnings.

- [ ] **Step 2: Append the wave close-out summary** to `TDD_IMPLEMENTATION_STATUS.md` (next entry number), per the §25 close-out format: what shipped, commits, verification counts, and gray areas:
  - Assignees are list-payload-only: a card freshly opened via detail (never pulled) shows the last-pulled blob; reconciliation is the next pull.
  - `has_more_assignees` is not decoded — cards with truncated assignee lists show only the embedded page (document as MVP limitation).
  - Avatar images deferred (auth-header problem) — initials only.
  - Echo-PUT after a successful toggle (modifiedAt bump → next sync pushes; assignees aren't in the PUT payload so nothing is clobbered) — same known minor as tags.

- [ ] **Step 3: Commit** — `git commit -m "docs: log #19 wave 2 (assignments) in TDD status"`

- [ ] **Step 4: Report back to the Captain** — what shipped, test delta, deviations, and a proposed #19 comment (GitHub posting needs fresh explicit approval).

---

## Known risks & decisions encoded above

1. **Storage = JSON blob** (`assigneesData` Binary on Card) — Captain's ruling; additive-only v7 lightweight migration is the lowest-risk CoreData change possible. CloudKit: a new optional attribute is schema-additive (no re-export problem for existing rows' OTHER fields; the blob itself only populates on next pull — acceptable, remote-authoritative data).
2. **Initials-only avatars** — Captain's ruling; `avatar_url` needs the bearer token and AsyncImage can't send headers. Decoded anyway (DTO has it) so a future authenticated loader needs no wire change.
3. **`assignees == nil` (key absent) leaves the blob alone** — the single-card doc and PUT responses don't carry assignees; overwriting on nil would wipe data on every detail-driven code path that calls applyRemote.
4. **Unpaired cards have no assignments** — `toggleAssignment` guards at the top; the row is gated on `canEditAssignments`.
5. **Toggle endpoint is a server-side toggle** (`POST /cards/:n/assignments`) — idempotency caveat: a revert-after-failure does NOT need a compensating POST (the POST never landed); a SUCCESSFUL toggle followed by a local-only revert would desync — which is why the revert only happens in the catch path.
