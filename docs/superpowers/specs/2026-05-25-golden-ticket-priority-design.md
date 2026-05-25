# Golden Ticket Priority — Design Spec

- **Date:** 2026-05-25
- **Status:** Design approved; ready for implementation plan (via writing-plans skill)
- **Inspiration:** Fizzy.do's `golden: bool` card field. See [help.fizzy.do/3/fizzy-help-guide/50/moving-prioritizing](https://help.fizzy.do/3/fizzy-help-guide/50/moving-prioritizing) and [github.com/basecamp/fizzy/tree/main/docs/api](https://github.com/basecamp/fizzy/tree/main/docs/api).

## Goal

Give FenixKanban a single, scarce-by-convention way to mark *real* important cards — the "golden ticket" metaphor. One flag per card; golden cards visually distinct (gold-tinted Liquid Glass + ticket icon) and floated to the top of their column. No competing priority axis.

## Non-goals

- Replacing or restructuring the existing `Label` system.
- Multi-tier priority (P0/P1/P2 etc.).
- Per-user pins (Fizzy's separate, complementary concept — different table, different metaphor).
- Custom shimmer / sparkle / particle effects (would suppress Liquid Glass per `feedback_apple_liquid_glass`).
- Cross-board card moves (the app doesn't support these today).

## Design decisions (decided in brainstorming)

| Question | Decision | Notes |
| --- | --- | --- |
| Scarcity model | Pure metaphor, no per-board cap | Matches Fizzy. Discipline is on the user. |
| Toggle surfaces | All four: CardDetailView toolbar, context menu, swipe, drag-to-gold-zone | Maximum entry points; users can discover whichever feels natural. |
| Sort behavior | Golden cards always float to top of column | Manual reorder within each group still works. |
| Visual treatment | Tinted glass throughout + ticket SF Symbol top-leading | Strongest "this is the golden one" signal; matches Fizzy's icon location. |
| Drop zone location | Inside column header | Contained — lives where it's needed. |
| App Intents integration | `ToggleGoldenIntent` + `FindGoldenCardsIntent` (Shortcuts query) | Toggle for Siri, query for Shortcuts chains. |
| Swipe implementation | Custom `DragGesture()` modifier on `CardView`, iOS only | `.swipeActions` is List-only; cards live in `LazyVStack` for drag/drop. |
| Gold chip visibility | Always visible in column header | Discoverability; avoids "is a drag in flight" SwiftUI plumbing. |

---

## Section 1 — Data model & migration

Add one attribute to the `Card` entity in `Core/Persistence/FenixKanban.xcdatamodeld`:

```
isGolden : Boolean (not optional) defaultValueString="NO" usesScalarValueType=YES
```

### Migration steps

1. Bump `.xccurrentversion` to a new version named `FenixKanban 2.xcdatamodel`.
2. Lightweight migration (`shouldMigrateStoreAutomatically = true`, `shouldInferMappingModelAutomatically = true` — already default in `PersistenceController`).
3. Existing CloudKit records get `isGolden = NO` on first fetch; no remote re-upload required (CloudKit absent-key → CoreData default).

### Optional ergonomics

```swift
extension Card {
    var isGoldenTicket: Bool { get { isGolden } set { isGolden = newValue } }
}
```

So call sites read `card.isGoldenTicket` (the metaphor name) without an attribute rename. Pure convenience; remove if it feels redundant.

---

## Section 2 — Sort behavior: always-float-to-top

One composite sort descriptor on the existing Card fetch — no new sort field, no separate "pinned" collection.

```swift
request.sortDescriptors = [
    NSSortDescriptor(key: "isGolden", ascending: false),  // true before false
    NSSortDescriptor(key: "sortOrder", ascending: true),
]
```

Within each group, manual reorder works exactly as today. Drag-to-reorder updates `sortOrder` like normal. The composite sort just guarantees golden cards visually outrank non-golden ones regardless of `sortOrder` value.

### Edge-case behavior (intentional)

- Drag a non-golden card *above* a golden card → the `sortOrder` change persists, but the composite sort snaps it back below the golden group. Reads as "you can't outrank the golden ticket without making yours golden too." Pure metaphor enforcement, no extra code.
- Drag a golden card *below* a non-golden card → same snap-back; golden stays on top.
- Move a card to another column → `isGolden` follows the card, so it floats to the top of the destination column.

### Files touched

- `Core/Persistence/CardRepository.swift` — update fetch sort descriptors (single line).
- `Features/Board/BoardViewModel.swift` — any in-memory re-sort uses the same key order.
- The `LazyVStack` in `Features/Board/ColumnView.swift` renders the pre-sorted array; no SwiftUI changes for sort.

No "Golden" section header. The tinted glass + ticket icon (Section 3a) is the only visual cue at the top of the column — keeps the column visually one continuous list, matches Fizzy.

---

## Section 3 — Toggle surfaces + visual treatment

### 3a — Visual treatment

`CardView` currently uses `.glassEffect(.regular.tint(glassTint))` where `glassTint` is computed from the optional `columnColor` (`columnColor?.opacity(0.18) ?? .clear`). Override that computed property to return the gold tint when `card.isGoldenTicket` is true, and overlay a ticket SF Symbol in the top-leading corner.

```swift
// in CardView
private var glassTint: Color {
    if card.isGoldenTicket {
        return .goldenTicket
    }
    return columnColor?.opacity(0.18) ?? .clear
}

// existing body unchanged at the .glassEffect call site; new overlay:
content
    .glassEffect(.regular.tint(glassTint), in: .rect(cornerRadius: 8))
    .overlay(alignment: .topLeading) {
        if card.isGoldenTicket {
            Image(systemName: "ticket.fill")
                .imageScale(.medium)
                .foregroundStyle(.goldenTicketIcon)
                .padding(8)
                .accessibilityLabel("Golden ticket priority")
        }
    }
```

New colors in `Extensions/Color+CrossPlatform.swift`, with Increase-Contrast variants per the project's accessibility memory (`feedback_apple_a11y_ios26`):

```swift
static let goldenTicket = Color(red: 0.95, green: 0.78, blue: 0.20)
static let goldenTicketIcon = Color(red: 0.55, green: 0.40, blue: 0.05)
// + .goldenTicketContrast / .goldenTicketIconContrast — used when
//   UIAccessibility.isDarkerSystemColorsEnabled (iOS) or
//   NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast (macOS).
```

No custom shadow / no shimmer / no gradient overlay — Liquid Glass renders depth and refraction at run-time. The column's card stack is already wrapped in `GlassEffectContainer` (commit `cb19636`) so the gold glass batches with neighbors.

### 3b — `CardDetailView` toolbar button (Fizzy's match)

```swift
.toolbar {
    ToolbarItem(placement: .topBarLeading) {  // .navigation on macOS
        Button {
            viewModel.toggleGolden()
        } label: {
            Image(systemName: card.isGoldenTicket ? "ticket.fill" : "ticket")
        }
        .tint(card.isGoldenTicket ? .goldenTicketIcon : .primary)
        .accessibilityLabel(card.isGoldenTicket ? "Remove golden ticket" : "Mark as golden ticket")
        .accessibilityHint("Promotes this card to the top of the column.")
    }
}
```

### 3c — Context menu item

Add to the existing `.contextMenu` on `CardView`. Top of the menu — highest-leverage action:

```swift
Button {
    viewModel.toggleGolden(for: card)
} label: {
    SwiftUI.Label(
        card.isGoldenTicket ? "Remove Golden Ticket" : "Mark as Golden",
        systemImage: card.isGoldenTicket ? "ticket.slash" : "ticket"
    )
}
```

### 3d — Swipe action (iOS only, custom modifier)

SwiftUI's `.swipeActions(...)` only works inside `List`. Cards live in `LazyVStack`. Implementation: custom `GoldenSwipeModifier` using `DragGesture()` — recognize trailing horizontal drag past ~80pt, animate a gold "Mark Golden" pill into view, tap toggles. Scoped behind `#if os(iOS)` since macOS doesn't use swipe-row patterns.

```swift
struct GoldenSwipeModifier: ViewModifier {
    let isGolden: Bool
    let onToggle: () -> Void
    @State private var offset: CGFloat = 0
    @State private var revealed = false

    func body(content: Content) -> some View {
        // ZStack: revealed gold pill underneath; content draggable on top.
        // DragGesture(minimumDistance: 20) tracks horizontal translation,
        // clamped to negative range, snaps to revealed (≤ -80) or closed.
        // Tapping the revealed pill calls onToggle() then closes.
    }
}
```

**Coexistence with existing `.draggable`:** the column's `.draggable(card.id?.uuidString)` triggers on long-press (the default for `.draggable` on iOS). The swipe gesture uses `DragGesture(minimumDistance: 20)` with an initial direction check (must be primarily horizontal). The two should coexist; testing on iPhone simulator during implementation will confirm.

### 3e — Drag-to-gold-zone in column header

New component `Components/GoldZoneChip.swift` — a gold capsule with a ticket icon, **always visible** in the column header. Uses the existing `.draggable(card.id?.uuidString)` payload.

```swift
struct GoldZoneChip: View {
    let onDropCardID: (String) -> Void
    @State private var isTargeted = false
    var body: some View {
        Image(systemName: "ticket.fill")
            .imageScale(.small)
            .foregroundStyle(.goldenTicketIcon)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(
                .regular.tint(isTargeted ? .goldenTicket : .goldenTicket.opacity(0.5)),
                in: .capsule
            )
            .dropDestination(for: String.self) { items, _ in
                guard let uuid = items.first else { return false }
                onDropCardID(uuid)
                return true
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel("Drop here to mark golden")
    }
}
```

**Column header integration:** the column header is rendered inline at the top of `Features/Board/ColumnView.swift` (no separate `ColumnHeaderView` type today). Place the `GoldZoneChip` in that header's `HStack`, trailing the column name. Drop handler calls `BoardViewModel.toggleGolden(cardID: UUID)`. Card keeps its column; `isGolden = true` and the column re-sort lifts it to the top. Extracting a dedicated `ColumnHeaderView` is **not** in scope for this work — keep the chip inline in `ColumnView`.

Always-visible chip (not show-only-while-dragging) chosen for discoverability and to avoid the SwiftUI "is-a-drag-in-flight" plumbing.

---

## Section 4 — App Intents

### 4a — Extend `CardEntity` with `isGolden`

```swift
struct CardEntity: AppEntity {
    // ...existing fields
    var isGolden: Bool  // NEW

    init(from card: Card) throws {
        // ...existing
        self.isGolden = card.isGolden  // NEW
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: isGolden ? "Golden ticket" : nil
        )
    }
}
```

Surfaces gold state in any context where a `CardEntity` appears (e.g., the existing `OpenCardIntent`'s pickers).

### 4b — `ToggleGoldenIntent` (action)

```swift
// Features/Intents/ToggleGoldenIntent.swift
struct ToggleGoldenIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Golden Ticket"
    static var description = IntentDescription(
        "Marks or unmarks a card as golden — promotes it to the top of its column."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Card") var card: CardEntity

    var contextOverride: NSManagedObjectContext?
    @Dependency private var context: NSManagedObjectContext
    private var resolvedContext: NSManagedObjectContext { contextOverride ?? context }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<CardEntity> {
        let id = card.id
        let updated: Card = try await resolvedContext.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let card = try resolvedContext.fetch(request).first else {
                throw $card.needsValueError("That card no longer exists.")
            }
            card.isGolden.toggle()
            card.modifiedAt = .now
            try resolvedContext.save()
            return card
        }
        let entity = try CardEntity(from: updated)
        let dialog = IntentDialog(
            full: entity.isGolden
                ? "Marked \(entity.title) as the golden ticket."
                : "Removed golden ticket from \(entity.title)."
        )
        return .result(value: entity, dialog: dialog)
    }
}
```

`ProvidesDialog` so Siri/Shortcuts speak a confirmation. `ReturnsValue<CardEntity>` so the action chains.

### 4c — `FindGoldenCardsIntent` (query as action)

```swift
// Features/Intents/FindGoldenCardsIntent.swift
struct FindGoldenCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Golden Cards"
    static var description = IntentDescription(
        "Returns the cards currently marked as golden, optionally scoped to one board."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Board",
        description: "Limit results to one board. Leave empty for all boards.",
        default: nil
    )
    var board: BoardEntity?

    var contextOverride: NSManagedObjectContext?
    @Dependency private var context: NSManagedObjectContext
    private var resolvedContext: NSManagedObjectContext { contextOverride ?? context }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        let boardID = board?.id
        let entities: [CardEntity] = try await resolvedContext.perform {
            let request = Card.fetchRequest()
            if let boardID {
                request.predicate = NSPredicate(
                    format: "isGolden == YES AND column.board.id == %@",
                    boardID as CVarArg
                )
            } else {
                request.predicate = NSPredicate(format: "isGolden == YES")
            }
            request.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
            return try resolvedContext.fetch(request).compactMap { try? CardEntity(from: $0) }
        }
        return .result(value: entities)
    }
}
```

### 4d — `FenixKanbanShortcuts` registration

```swift
AppShortcut(
    intent: ToggleGoldenIntent(),
    phrases: [
        "Mark the golden ticket in \(.applicationName)",
        "Toggle golden ticket in \(.applicationName)",
    ],
    shortTitle: "Toggle Golden",
    systemImageName: "ticket.fill"
)
AppShortcut(
    intent: FindGoldenCardsIntent(),
    phrases: [
        "Show my golden tickets in \(.applicationName)",
        "Find golden cards in \(.applicationName)",
    ],
    shortTitle: "Find Golden Cards",
    systemImageName: "ticket"
)
```

---

## Section 5 — CloudKit sync

### 5a — Schema migration is lightweight

Adding a non-optional `Boolean` with `defaultValueString="NO"` qualifies as a lightweight migration. The field is added to the same `Card` entity, so it picks up the entity's existing CloudKit flag automatically.

### 5b — Existing records read cleanly

Old records on CloudKit don't have an `isGolden` field. When `NSPersistentCloudKitContainer` materializes them locally, the CoreData default (`NO`) fills in. No bulk migration job needed.

### 5c — Conflict resolution

NSPersistentCloudKitContainer uses last-writer-wins by attribute under the hood. `ToggleGoldenIntent` and `BoardViewModel.toggleGolden(for:)` both update `modifiedAt = .now` for visible ordering. No custom merge resolver needed.

### 5d — Old build / new build coexistence is safe

- Old build *reads* a record with `isGolden` → `CKRecord` exposes only known fields; unknown ones are silently ignored. No crash.
- Old build *writes* a record → NSPersistentCloudKitContainer only emits fields it knows about. Unknown CloudKit fields (including `isGolden`) are **left untouched**, not cleared.

### 5e — Push wake-up already in place

The `UIBackgroundModes = [remote-notification]` we added in commit `083ba54` is exactly what NSPersistentCloudKitContainer needs to wake the app for remote `isGolden` changes. No new entitlement, no new subscription — the existing `Card` subscription covers all attributes on the entity.

### 5f — Production schema deploy (release-time)

**Release checklist item — manual step.** CloudKit Development environment auto-promotes schema as soon as the first build writes the new field. Production requires a manual deploy:

> Before the App Store release that includes this feature, open the CloudKit Dashboard → Container `iCloud.com.bluefenixproductions.FenixKanban` → Schema → Deploy Schema Changes to Production.

If the build ships without this step, end-users' first attempt to sync `isGolden` to Production fails. The app stays functional locally; sync resumes for the field once the dashboard step happens. To be added to the outstanding-items list in `TDD_IMPLEMENTATION_STATUS.md`.

---

## Section 6 — TDD plan

Per CLAUDE.md, every layer gets Red → Green → Refactor with Swift Testing's `@Test` macro. Visual/UI behavior is verified manually.

### Test files

| File | Layer | Covers |
| --- | --- | --- |
| `FenixKanbanTests/Models/CardGoldenTicketTests.swift` | CoreData | `isGolden` defaults to NO; persists across save/fetch; migration runs cleanly. |
| `FenixKanbanTests/Repositories/CardRepositoryGoldenSortTests.swift` | Fetch / sort | Composite sort puts golden cards before non-golden regardless of `sortOrder`; manual reorder within each group still works; moving a golden card between columns keeps `isGolden=YES`. |
| `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift` | View model | `toggleGolden(for:)` flips `isGolden`, updates `modifiedAt`, and re-orders the cards array. |
| `FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift` | App Intent | `perform()` toggles state, returns the updated `CardEntity`, throws `needsValueError` when card is missing, dialog reflects new state. |
| `FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift` | App Intent | Returns only golden cards; board filter scopes correctly; empty board param returns all golden across boards; result ordered by `modifiedAt` desc. |

All use `PersistenceController(inMemory: true, useCloudKit: false)` — the existing in-memory pattern from `BoardListViewModelTests` etc.

### Sampled test cases

```swift
// CardGoldenTicketTests.swift
@Test("isGolden defaults to false on a fresh insert")
func goldenDefault() throws {
    let card = Card(context: ctx)
    card.id = UUID(); card.title = "Test"
    try ctx.save()
    #expect(card.isGolden == false)
}

// CardRepositoryGoldenSortTests.swift
@Test("Golden card sorts above non-golden with lower sortOrder")
func goldenFloatsAbove() throws {
    let a = makeCard(title: "A", sortOrder: 0, isGolden: false)
    let b = makeCard(title: "B", sortOrder: 1, isGolden: true)
    let c = makeCard(title: "C", sortOrder: 2, isGolden: false)
    let fetched = repo.fetchCards(for: column)
    #expect(fetched.map(\.title) == ["B", "A", "C"])
}

// BoardViewModelGoldenTests.swift
@Test("Toggling golden updates modifiedAt and re-sorts")
func toggleReorders() async throws {
    let card = makeCard(title: "X", sortOrder: 5, isGolden: false)
    let before = card.modifiedAt
    viewModel.toggleGolden(for: card)
    #expect(card.isGolden == true)
    #expect(card.modifiedAt != before)
    #expect(viewModel.cards(in: column).first === card)
}

// ToggleGoldenIntentTests.swift
@Test("ToggleGoldenIntent dialog reflects new state")
func dialogIsContextual() async throws {
    let card = makeCard(title: "Pay rent", isGolden: false)
    var intent = ToggleGoldenIntent(card: try CardEntity(from: card))
    intent._injectDependencies(context: ctx)
    let result = try await intent.perform()
    #expect(result.value?.isGolden == true)
}

// FindGoldenCardsIntentTests.swift
@Test("Find scoped to one board excludes other boards' golden cards")
func boardScope() async throws {
    let boardA = makeBoard(name: "Sprint 14")
    let boardB = makeBoard(name: "Sprint 15")
    makeCard(in: boardA, title: "A1", isGolden: true)
    makeCard(in: boardB, title: "B1", isGolden: true)
    var intent = FindGoldenCardsIntent(board: try BoardEntity(from: boardA))
    intent._injectDependencies(context: ctx)
    let result = try await intent.perform()
    #expect(result.value?.map(\.title) == ["A1"])
}
```

### Order of work (TDD phasing)

Each step is its own Red → Green → Refactor cycle, each ending in a commit:

1. **CoreData attribute** — Red: `CardGoldenTicketTests.swift` fails. Green: add `isGolden` attribute + bump xcdatamodel version. Refactor: nothing.
2. **Sort behavior** — Red: `CardRepositoryGoldenSortTests.swift` fails. Green: update sort descriptors in `CardRepository`. Refactor: nothing.
3. **ViewModel toggle** — Red: `BoardViewModelGoldenTests.swift` fails; add a `toggleGolden` case to the existing `CardDetailViewModelTests.swift`. Green: add `toggleGolden(for:)` and `toggleGolden(cardID:)` to `BoardViewModel`, and `toggleGolden()` to `CardDetailViewModel` (the toolbar button in 3b calls it). Refactor: extract a `Card.toggleGolden(in:)` helper if it removes duplication across the two view models.
4. **Visual treatment** — no automated test. Green: edit `CardView` + `Color+CrossPlatform`. Manual verification: build, eyeball a golden card on both platforms.
5. **Toggle surfaces** (3b/3c/3d/3e) — each is a small Green step with manual verification:
   - 3b — Toolbar button in `CardDetailView`.
   - 3c — Context menu item on `CardView`.
   - 3d — `GoldenSwipeModifier` (iOS only).
   - 3e — `GoldZoneChip` component + `ColumnHeaderView` integration.
6. **App Intents** — Red: `ToggleGoldenIntentTests.swift` then `FindGoldenCardsIntentTests.swift`. Green: write the two intents + extend `CardEntity` + register `AppShortcut`s.
7. **Documentation** — append a new section to `TDD_IMPLEMENTATION_STATUS.md`; add the CloudKit production-schema deploy step to outstanding items.

### What's manual (and why)

- **Liquid Glass rendering** — no programmatic way to assert "the card looks golden." Build + visual verification.
- **Drag-and-drop on the gold chip** — SwiftUI `dropDestination` is hard to unit-test without UI testing infrastructure. The `BoardViewModel.toggleGolden(cardID:)` call it makes IS unit-tested.
- **CloudKit round-trip** — requires a real iCloud container. Manual: build to two devices on the same iCloud account, mark a card on one, watch it gold on the other.
- **VoiceOver / Increase Contrast** — verify manually per the walkthrough in `docs/accessibility-walkthrough.md`.

---

## Section 7 — Scope guard-rails

### In scope (this feature)

- `Card.isGolden` attribute + `FenixKanban 2.xcdatamodel` lightweight migration.
- Composite sort `(isGolden DESC, sortOrder ASC)` in `CardRepository` + `BoardViewModel`.
- Tinted-glass-plus-ticket-icon visual treatment in `CardView`.
- Four toggle surfaces: `CardDetailView` toolbar, context menu, custom iOS swipe modifier, `GoldZoneChip` in column header.
- `Color.goldenTicket` + `.goldenTicketIcon` + Increase-Contrast variants in `Extensions/Color+CrossPlatform.swift`.
- `ToggleGoldenIntent` + `FindGoldenCardsIntent` + `CardEntity.isGolden` + two new `AppShortcut` registrations.
- Five new test files (Section 6).
- `TDD_IMPLEMENTATION_STATUS.md` log entry.
- Release-checklist item: CloudKit Production schema promotion.

### Deferred follow-ups

- Per-board golden-ticket cap / configurability (revisit if discipline visibly breaks down).
- Labeled "★ Golden" section header at top of column.
- Toggle animation flourishes beyond the natural sort-reorder animation.
- Spotlight indexing of golden cards as a separate domain (Core Spotlight is its own milestone).
- Per-user pins (Fizzy's separate concept — different feature).

### Explicitly out of scope

- Touching the existing `Label` system.
- Reworking column rendering from `LazyVStack` to `List`.
- Cross-board card moves.
- Custom shimmer / sparkle / particle effects.
- Push notifications when a card becomes golden.

### Risk areas

- **CloudKit Production schema deploy** is manual. Release-checklist item exists for that reason; if missed, sync of `isGolden` breaks for App Store users until the dashboard step happens.
- **Custom iOS swipe gesture** has to coexist with the existing `.draggable` on each `CardView`. The horizontal drag direction lives in the same gesture region — tuning `minimumDistance` and direction recognition will be the most fiddly implementation detail. Plan: implement, then test on iPhone simulator with both gestures to find any conflicts.

---

## Implementation entry point

Next step is to invoke the `writing-plans` skill to produce a sequenced implementation plan from this design. Implementation will follow Red → Green → Refactor per CLAUDE.md, with atomic commits per phase as listed in Section 6.
