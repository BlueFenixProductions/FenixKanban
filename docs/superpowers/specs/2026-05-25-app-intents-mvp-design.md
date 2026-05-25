# App Intents MVP — Design

**Date:** 2026-05-25
**Scope:** Add minimum App Intents adoption so FenixKanban's boards and cards are addressable from Siri and Shortcuts. **Core Spotlight integration is explicitly out of scope** — cancelled by user.

## Background

Apple's Technology Overviews recommend adopting App Intents (`AppEntity` + `AppIntent`) as the universal vocabulary for app content and actions on iOS 26 / macOS 26 — this surfaces an app to Siri, Shortcuts, Spotlight, Focus Filters, Apple Intelligence, and Visual Intelligence without per-surface code (see [`docs/apple-technology-overviews.md`](../../apple-technology-overviews.md)).

This spec captures the MVP slice: model `Board` and `Card` as `AppEntity`, expose `OpenBoard` and `OpenCard` intents, and register them via an `AppShortcutsProvider`. Spotlight indexing of those entities (the natural next step) is deferred.

## Goals

- After install, the Shortcuts app shows FenixKanban with two actions: **Open Board** and **Open Card**, each parameterizable by a board / card from a picker that lists the user's actual data.
- Siri honors phrases like *"Open Bug Triage in FenixKanban"* and *"Open the card called X in FenixKanban"* — opening the app and navigating to the requested board/card.
- The 78-test regression suite continues to pass; iOS 26 + macOS 26 builds continue to succeed.
- Existing UI behavior is unchanged when the app is launched normally (not via intent).

## Non-Goals

- Core Spotlight indexing of cards/boards (no `CSSearchableIndex`, no `NSUserActivity` donation for indexing, no `.onContinueUserActivity(CSSearchableItemActionType:)` routing). **Cancelled.**
- Write intents (`CreateBoard`, `CreateCard`, `CompleteCard`, `MoveCard`, `DeleteCard`, `SetLabel`) — deferred to a Standard-tier follow-up.
- `Label` as `AppEntity` — deferred.
- Focus Filters, custom Siri snippets, Visual Intelligence donations — deferred.
- TDD red-green-refactor for non-logic glue files (`FenixKanbanShortcuts`, `NavigationModel` mutation wiring). Entity transforms and intent `perform()` get tests; the `AppShortcutsProvider` declaration is a Swift literal that the system parses at install time and is verified by the Shortcuts app showing the actions.

## Architecture

**Pattern:** classic App Intents MVP. The intents mutate a shared `NavigationModel` (`@Observable`) that is also held by `ContentView`. Navigation happens reactively — the intent doesn't open URLs, it just updates state and lets SwiftUI re-render.

```
┌─────────────────────────┐         ┌──────────────────────┐
│ Siri / Shortcuts        │         │ FenixKanbanApp       │
│   ↓ invokes             │         │   .scene             │
│ OpenBoardIntent         │ ──→     │   .environment(navigator)
│   .perform()            │         │     ↓                │
│     navigator.openBoard │         │   ContentView reads  │
│       (board.id)        │         │   navigator.selected*│
│                         │         │     → re-renders     │
└─────────────────────────┘         └──────────────────────┘
            ▲
            │ @Dependency var navigator
            │ (registered at app launch via
            │  AppDependencyManager.shared.add(...))
            │
        Same instance
```

**Why `@Observable` not `ObservableObject`?** iOS 26 / macOS 26 baseline; `@Observable` is the modern pattern (`feedback-fenixkanban-deployment-targets`). Plays well with App Intents' `@Dependency` injection.

**Why mutate state instead of returning `.opensIntent(...)`?** The opensIntent pattern is for *chaining* intents, not for app-side navigation. For "open this thing in my app," the documented modern pattern is `openAppWhenRun: true` + `@Dependency`-injected app state.

## File Structure

**New files:**

- `FenixKanban/Core/Navigation/NavigationModel.swift` — tiny `@Observable` class with `selectedBoardID: NSManagedObjectID?` and `selectedCardID: NSManagedObjectID?`. Conforms to a small `IntentNavigating` protocol so tests can use a fake.
- `FenixKanban/Features/Intents/BoardEntity.swift` — `AppEntity` representation of `Board` (id, displayName from `name`).
- `FenixKanban/Features/Intents/BoardQuery.swift` — `EntityQuery` that fetches boards from Core Data (by ID, all, suggested).
- `FenixKanban/Features/Intents/CardEntity.swift` — `AppEntity` representation of `Card` (id, displayName from `title`, parent `BoardEntity`).
- `FenixKanban/Features/Intents/CardQuery.swift` — `EntityQuery` for cards (by ID, all, suggested).
- `FenixKanban/Features/Intents/OpenBoardIntent.swift` — `AppIntent` with `@Parameter var board: BoardEntity` and `@Dependency var navigator: NavigationModel`. `openAppWhenRun = true`. `perform()` writes `navigator.selectedBoardID`.
- `FenixKanban/Features/Intents/OpenCardIntent.swift` — same shape, for cards.
- `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift` — `AppShortcutsProvider` declaring the two intents with invocation phrases.

**Modified files:**

- `FenixKanban/FenixKanbanApp.swift`:
  - Add `@State private var navigator = NavigationModel()` (the model is `@Observable`, so `@State` is the right property wrapper, not `@StateObject`).
  - In `init()`: call `AppDependencyManager.shared.add(dependency: navigator)` so intents can `@Dependency` it. Registration must be synchronous so cold-launch from Siri works.
  - Pass `navigator` into `ContentView` so the existing `@State selectedBoardID` is replaced by `navigator.selectedBoardID`.
  - On intent-driven `selectedCardID` change, present the `CardDetailView` sheet (extend `ContentView` minimally).

**Test files (Swift Testing, `.serialized` for any Core Data-touching suite per the existing project pattern):**

- `FenixKanbanTests/Intents/BoardEntityTests.swift`
- `FenixKanbanTests/Intents/CardEntityTests.swift`
- `FenixKanbanTests/Intents/OpenBoardIntentTests.swift`
- `FenixKanbanTests/Intents/OpenCardIntentTests.swift`
- `FenixKanbanTests/Core/NavigationModelTests.swift`

**No test for `FenixKanbanShortcuts.swift`** — it's a static declaration the system parses at install time. The Shortcuts app showing the two actions post-install is the acceptance criterion.

## Detailed designs

### `NavigationModel`

```swift
import CoreData
import Observation

@Observable
@MainActor
final class NavigationModel {
    var selectedBoardID: NSManagedObjectID?
    var selectedCardID: NSManagedObjectID?

    /// Look up a Board by its UUID `id` field and set `selectedBoardID` to the
    /// matching `objectID`. Used by `OpenBoardIntent`; returns whether a match
    /// was found so the intent can throw a meaningful error if not.
    @discardableResult
    func openBoard(uuid: UUID, in context: NSManagedObjectContext) -> Bool { /* ... */ }

    @discardableResult
    func openCard(uuid: UUID, in context: NSManagedObjectContext) -> Bool { /* ... */ }
}
```

### `BoardEntity`

```swift
import AppIntents

struct BoardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
    static var defaultQuery = BoardQuery()

    var id: UUID
    var name: String
    var colorHex: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}
```

`init(from: Board)` constructor reads from the managed object.

### `BoardQuery`

```swift
import AppIntents
import CoreData

struct BoardQuery: EntityQuery {
    @Dependency private var context: NSManagedObjectContext

    func entities(for identifiers: [UUID]) async throws -> [BoardEntity] { /* fetch Boards where id IN identifiers */ }
    func suggestedEntities() async throws -> [BoardEntity] { /* fetch all Boards sorted */ }
}
```

The `NSManagedObjectContext` is registered as an `IntentDependency` at app launch alongside the `NavigationModel`.

### `OpenBoardIntent`

```swift
import AppIntents

struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens the specified board in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Board") var board: BoardEntity

    @Dependency private var navigator: NavigationModel
    @Dependency private var context: NSManagedObjectContext

    @MainActor
    func perform() async throws -> some IntentResult {
        let opened = navigator.openBoard(uuid: board.id, in: context)
        if !opened {
            throw $board.needsValueError("That board no longer exists.")
        }
        return .result()
    }
}
```

`OpenCardIntent` follows the same shape.

### `FenixKanbanShortcuts`

```swift
import AppIntents

struct FenixKanbanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: [
                "Open \(\.$board) in \(.applicationName)",
                "Show \(\.$board) in \(.applicationName)"
            ],
            shortTitle: "Open Board",
            systemImageName: "rectangle.3.group"
        )
        AppShortcut(
            intent: OpenCardIntent(),
            phrases: [
                "Open \(\.$card) in \(.applicationName)",
                "Show \(\.$card) in \(.applicationName)"
            ],
            shortTitle: "Open Card",
            systemImageName: "doc.text"
        )
    }
}
```

### `FenixKanbanApp` integration

```swift
@main
struct FenixKanbanApp: App {
    @State private var navigator = NavigationModel()
    // ... existing properties ...

    init() {
        // ... existing init body ...
        AppDependencyManager.shared.add(dependency: navigator)
        AppDependencyManager.shared.add(dependency: PersistenceController.shared.container.viewContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(navigator: navigator)
                .environment(\.managedObjectContext, persistence.viewContext)
                // ... existing modifiers ...
        }
    }
}

struct ContentView: View {
    @Bindable var navigator: NavigationModel
    // ... existing other properties, but replace @State selectedBoardID ...
}
```

The card-detail sheet logic in `ContentView` watches `navigator.selectedCardID` and presents accordingly.

## Test Plan

- `BoardEntityTests` / `CardEntityTests`: round-trip the managed object → AppEntity transformation. Verify `id`, `name`/`title`, `displayRepresentation`. Use an in-memory `PersistenceController` per the project's existing pattern.
- `OpenBoardIntentTests` / `OpenCardIntentTests`: instantiate the intent with a fake `NavigationModel`, call `perform()`, assert the navigator's `selectedBoardID` / `selectedCardID` was set. Test the "board no longer exists" path throws.
- `NavigationModelTests`: `openBoard(uuid:in:)` finds existing boards by UUID and sets `selectedBoardID` to the matching `objectID`; returns false and leaves state unchanged when the UUID isn't found.
- All new test suites are `@MainActor` (the navigator and intent perform run on main).

## Risks & Mitigations

- **Risk:** `@Dependency` requires `AppDependencyManager.shared.add(dependency:)` *before* any intent perform runs. If FenixKanban is cold-launched from Siri, that registration must happen synchronously in `init()`, not in a `.task`.
  - **Mitigation:** Register in `init()`, not in a SwiftUI lifecycle hook. The spec above does this.
- **Risk:** `NSManagedObjectContext` isn't `Sendable`; passing it as `@Dependency` may produce strict-concurrency warnings.
  - **Mitigation:** Annotate the dependency context as `@MainActor`-bound. The `viewContext` is main-actor anyway.
- **Risk:** Cold-launch race — the intent's `perform()` runs before `ContentView` has rendered, so the navigator state update might be observed by an unrendered view.
  - **Mitigation:** `ContentView` reads navigator state on first appear; SwiftUI re-renders when the `@Bindable` model changes. Race is benign.
- **Risk:** `AppShortcutsProvider` registration requires the app to launch once after install for the shortcuts to appear. Same for re-registering after an intent type changes.
  - **Mitigation:** Documented; not a code issue. Manual verification step in the plan covers this.

## Acceptance Criteria

- iOS 26 simulator build succeeds.
- macOS build succeeds (`CODE_SIGNING_ALLOWED=NO`).
- Full test suite passes (78 pre-existing + ~12 new = ~90 tests in ~17 suites).
- After installing the app on the simulator and launching once, opening the Shortcuts app on the same simulator and searching "FenixKanban" shows both "Open Board" and "Open Card" actions with the user's actual boards/cards in the parameter picker. (Manual verification.)
