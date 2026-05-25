# App Intents MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface FenixKanban's `Board` and `Card` to Siri / Shortcuts via App Intents, with a shared `@Observable NavigationModel` driving in-app navigation. **No Core Spotlight** (cancelled).

**Architecture:** New `Core/Navigation/NavigationModel.swift` holds `selectedBoardID` / `selectedCardID`. New `Features/Intents/` folder holds `Board`/`Card` `AppEntity`s, their `EntityQuery`s, two `AppIntent`s (`OpenBoardIntent`, `OpenCardIntent`), and an `AppShortcutsProvider`. The app registers `NavigationModel` and the Core Data view context as `IntentDependency` so intents can `@Dependency`-inject them. `FenixKanbanApp` / `ContentView` swap their existing `@State selectedBoardID` for `navigator.selectedBoardID`.

**Tech Stack:** Swift 5.9, SwiftUI, App Intents (iOS 26 / macOS 26 baseline), Swift Testing, xcodegen. Core Data view context held by `PersistenceController.shared`.

**Spec:** [`docs/superpowers/specs/2026-05-25-app-intents-mvp-design.md`](../specs/2026-05-25-app-intents-mvp-design.md)

---

## File Structure

**New source:**
- `FenixKanban/Core/Navigation/NavigationModel.swift`
- `FenixKanban/Features/Intents/BoardEntity.swift`
- `FenixKanban/Features/Intents/BoardQuery.swift`
- `FenixKanban/Features/Intents/CardEntity.swift`
- `FenixKanban/Features/Intents/CardQuery.swift`
- `FenixKanban/Features/Intents/OpenBoardIntent.swift`
- `FenixKanban/Features/Intents/OpenCardIntent.swift`
- `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`

**New tests:**
- `FenixKanbanTests/Core/NavigationModelTests.swift`
- `FenixKanbanTests/Intents/BoardEntityTests.swift`
- `FenixKanbanTests/Intents/CardEntityTests.swift`
- `FenixKanbanTests/Intents/OpenBoardIntentTests.swift`
- `FenixKanbanTests/Intents/OpenCardIntentTests.swift`

**Modified:**
- `FenixKanban/FenixKanbanApp.swift` (wire navigator, register dependencies, route card-sheet presentation)
- `TDD_IMPLEMENTATION_STATUS.md` (append section after all tasks done)

---

### Task 1: NavigationModel + tests

**Files:**
- Create: `FenixKanban/Core/Navigation/NavigationModel.swift`
- Create: `FenixKanbanTests/Core/NavigationModelTests.swift`

- [ ] **Step 1: Write the failing tests first (red phase)**

Create `FenixKanbanTests/Core/NavigationModelTests.swift`:

```swift
import Testing
import CoreData
@testable import FenixKanban

@Suite("Navigation Model", .serialized)
@MainActor
struct NavigationModelTests {

    private func makeContext() -> (PersistenceController, BoardRepository, CardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        return (persistence, boardRepo, cardRepo)
    }

    @Test func initialStateIsEmpty() {
        let model = NavigationModel()
        #expect(model.selectedBoardID == nil)
        #expect(model.selectedCardID == nil)
    }

    @Test func openBoardSetsSelectedBoardIDForExistingUUID() {
        let (persistence, repo, _) = makeContext()
        let board = repo.createBoard(name: "Test")
        let uuid = try! #require(board.id)
        let model = NavigationModel()

        let opened = model.openBoard(uuid: uuid, in: persistence.viewContext)

        #expect(opened == true)
        #expect(model.selectedBoardID == board.objectID)
    }

    @Test func openBoardReturnsFalseForMissingUUID() {
        let (persistence, _, _) = makeContext()
        let model = NavigationModel()

        let opened = model.openBoard(uuid: UUID(), in: persistence.viewContext)

        #expect(opened == false)
        #expect(model.selectedBoardID == nil)
    }

    @Test func openCardSetsSelectedCardIDForExistingUUID() {
        let (persistence, boardRepo, cardRepo) = makeContext()
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        let card = cardRepo.createCard(in: column, title: "Card")
        let uuid = try! #require(card.id)
        let model = NavigationModel()

        let opened = model.openCard(uuid: uuid, in: persistence.viewContext)

        #expect(opened == true)
        #expect(model.selectedCardID == card.objectID)
    }

    @Test func openCardReturnsFalseForMissingUUID() {
        let (persistence, _, _) = makeContext()
        let model = NavigationModel()

        let opened = model.openCard(uuid: UUID(), in: persistence.viewContext)

        #expect(opened == false)
        #expect(model.selectedCardID == nil)
    }
}
```

- [ ] **Step 2: Run tests — they fail because `NavigationModel` doesn't exist**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E "Cannot find 'NavigationModel'|error:" | head -3`

Expected: errors like `Cannot find 'NavigationModel' in scope`.

(Skip running the full suite — the build will fail before any tests run, which is the desired red phase signal.)

- [ ] **Step 3: Implement `NavigationModel`**

Create `FenixKanban/Core/Navigation/NavigationModel.swift`:

```swift
import CoreData
import Observation

/// Holds the currently-selected board and card. Mutated by App Intents
/// (via `@Dependency`) and observed by `ContentView`.
@Observable
@MainActor
final class NavigationModel {
    var selectedBoardID: NSManagedObjectID?
    var selectedCardID: NSManagedObjectID?

    /// Look up a `Board` by its UUID `id` attribute and select it. Returns
    /// `true` when a match is found, `false` otherwise (state is left
    /// unchanged when not found, so a stale UUID doesn't clear navigation).
    @discardableResult
    func openBoard(uuid: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = Board.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let board = try? context.fetch(request).first else {
            return false
        }
        selectedBoardID = board.objectID
        return true
    }

    @discardableResult
    func openCard(uuid: UUID, in context: NSManagedObjectContext) -> Bool {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let card = try? context.fetch(request).first else {
            return false
        }
        selectedCardID = card.objectID
        return true
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project so xcodegen picks up the new files**

Run: `xcodegen generate 2>&1 | tail -3`
Expected: `Created project at ...`

- [ ] **Step 5: Run the tests — they should now pass**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E "Test run with|TEST" | tail -3`
Expected: `Test run with 83 tests in 15 suites passed` (78 pre-existing + 5 new), `** TEST SUCCEEDED **`.

- [ ] **Step 6: Build for macOS to confirm no platform-specific regressions**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Core/Navigation/NavigationModel.swift \
        FenixKanbanTests/Core/NavigationModelTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): add NavigationModel for shared selection state

Tiny @Observable model holding selectedBoardID / selectedCardID. Used by
ContentView (replacing its @State selectedBoardID) and by the upcoming
App Intents to drive in-app navigation. openBoard(uuid:in:) /
openCard(uuid:in:) look up a managed object by its UUID 'id' attribute
and stash the matching objectID; return false on miss so intents can
report a meaningful error."
```

---

### Task 2: BoardEntity + BoardQuery + tests

**Files:**
- Create: `FenixKanban/Features/Intents/BoardEntity.swift`
- Create: `FenixKanban/Features/Intents/BoardQuery.swift`
- Create: `FenixKanbanTests/Intents/BoardEntityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Intents/BoardEntityTests.swift`:

```swift
import Testing
import CoreData
@testable import FenixKanban

@Suite("Board Entity", .serialized)
@MainActor
struct BoardEntityTests {

    private func makeRepo() -> (PersistenceController, BoardRepository) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        return (persistence, repo)
    }

    @Test func initFromBoardPopulatesFields() throws {
        let (_, repo) = makeRepo()
        let board = repo.createBoard(name: "Bug Triage", colorHex: "#E94560")

        let entity = try BoardEntity(from: board)

        #expect(entity.id == board.id)
        #expect(entity.name == "Bug Triage")
        #expect(entity.colorHex == "#E94560")
    }

    @Test func initFromBoardThrowsWhenIdMissing() {
        let (persistence, _) = makeRepo()
        // Construct a Board directly so we can leave `id` nil.
        let board = Board(context: persistence.viewContext)
        board.name = "No-ID Board"

        #expect(throws: (any Error).self) {
            try BoardEntity(from: board)
        }
    }

    @Test func displayRepresentationUsesName() throws {
        let (_, repo) = makeRepo()
        let board = repo.createBoard(name: "Bug Triage")

        let entity = try BoardEntity(from: board)

        let repr = entity.displayRepresentation
        // String(describing:) is good enough — DisplayRepresentation is opaque
        // but its description includes the title.
        #expect(String(describing: repr).contains("Bug Triage"))
    }

    @Test func queryByIDReturnsMatchingBoards() async throws {
        let (persistence, repo) = makeRepo()
        let board1 = repo.createBoard(name: "One")
        let board2 = repo.createBoard(name: "Two")
        let uuid1 = try #require(board1.id)
        let uuid2 = try #require(board2.id)

        let query = BoardQuery(context: persistence.viewContext)
        let results = try await query.entities(for: [uuid1, uuid2])

        let names = Set(results.map(\.name))
        #expect(names == ["One", "Two"])
    }

    @Test func suggestedEntitiesReturnsAllBoardsSorted() async throws {
        let (persistence, repo) = makeRepo()
        _ = repo.createBoard(name: "Charlie")
        _ = repo.createBoard(name: "Alpha")
        _ = repo.createBoard(name: "Bravo")

        let query = BoardQuery(context: persistence.viewContext)
        let results = try await query.suggestedEntities()

        #expect(results.map(\.name) == ["Alpha", "Bravo", "Charlie"])
    }
}
```

- [ ] **Step 2: Verify the tests fail to build**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "Cannot find 'BoardEntity'|Cannot find 'BoardQuery'|error:" | head -3`
Expected: errors about missing `BoardEntity` / `BoardQuery`.

- [ ] **Step 3: Implement `BoardEntity`**

Create `FenixKanban/Features/Intents/BoardEntity.swift`:

```swift
import AppIntents
import CoreData

/// App Intents representation of a `Board`. Lets Siri / Shortcuts
/// reference boards by their UUID identifier.
struct BoardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Board")
    }

    static var defaultQuery = BoardQuery()

    var id: UUID
    var name: String
    var colorHex: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String, colorHex: String?) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    /// Convenience initializer from a managed `Board`.
    /// - Throws: `BoardEntityError.missingID` when the board has no UUID.
    init(from board: Board) throws {
        guard let id = board.id else {
            throw BoardEntityError.missingID
        }
        self.id = id
        self.name = board.name ?? "Untitled Board"
        self.colorHex = board.colorHex
    }
}

enum BoardEntityError: Error {
    case missingID
}
```

- [ ] **Step 4: Implement `BoardQuery`**

Create `FenixKanban/Features/Intents/BoardQuery.swift`:

```swift
import AppIntents
import CoreData

/// EntityQuery resolves `BoardEntity` values from Core Data — used by
/// Shortcuts pickers, Siri parameter resolution, and intent execution.
struct BoardQuery: EntityQuery {
    private let context: NSManagedObjectContext

    /// Default initializer used by App Intents at runtime; the system
    /// expects `defaultQuery` to be reachable without arguments. Falls
    /// back to `PersistenceController.shared.container.viewContext`.
    init() {
        self.context = PersistenceController.shared.container.viewContext
    }

    /// Test-only initializer — pass an in-memory context.
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func entities(for identifiers: [UUID]) async throws -> [BoardEntity] {
        try await context.perform {
            let request = Board.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", identifiers)
            let boards = try context.fetch(request)
            return boards.compactMap { try? BoardEntity(from: $0) }
        }
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        try await context.perform {
            let request = Board.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            let boards = try context.fetch(request)
            return boards.compactMap { try? BoardEntity(from: $0) }
        }
    }
}
```

- [ ] **Step 5: Regenerate, run tests**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E "Test run with|TEST" | tail -3
```
Expected: `Test run with 88 tests in 16 suites passed` (83 + 5 new), `** TEST SUCCEEDED **`.

- [ ] **Step 6: Confirm macOS build**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Features/Intents/BoardEntity.swift \
        FenixKanban/Features/Intents/BoardQuery.swift \
        FenixKanbanTests/Intents/BoardEntityTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): add BoardEntity and BoardQuery

BoardEntity wraps a Board for App Intents (id, name, colorHex,
displayRepresentation). BoardQuery resolves entities by UUID and
provides Shortcuts pickers with a sorted suggestedEntities() list.
Both fetch off Core Data's main viewContext at runtime; a test-only
initializer accepts an injected context for in-memory testing."
```

---

### Task 3: CardEntity + CardQuery + tests

**Files:**
- Create: `FenixKanban/Features/Intents/CardEntity.swift`
- Create: `FenixKanban/Features/Intents/CardQuery.swift`
- Create: `FenixKanbanTests/Intents/CardEntityTests.swift`

Same shape as Task 2. Card's natural fields: `id`, `title`, `description`, `dueDate`, `isCompleted`.

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Intents/CardEntityTests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card Entity", .serialized)
@MainActor
struct CardEntityTests {

    private func makeContext() -> (PersistenceController, BoardRepository, CardRepository, Column) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        return (persistence, boardRepo, cardRepo, column)
    }

    @Test func initFromCardPopulatesFields() throws {
        let (_, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Fix bug")
        cardRepo.updateCard(card, description: "Detail", dueDate: Date(timeIntervalSince1970: 100), isCompleted: false)

        let entity = try CardEntity(from: card)

        #expect(entity.id == card.id)
        #expect(entity.title == "Fix bug")
        #expect(entity.cardDescription == "Detail")
        #expect(entity.dueDate == Date(timeIntervalSince1970: 100))
        #expect(entity.isCompleted == false)
    }

    @Test func initFromCardThrowsWhenIdMissing() {
        let (persistence, _, _, _) = makeContext()
        let card = Card(context: persistence.viewContext)
        card.title = "No-ID Card"

        #expect(throws: (any Error).self) {
            try CardEntity(from: card)
        }
    }

    @Test func displayRepresentationUsesTitle() throws {
        let (_, _, cardRepo, column) = makeContext()
        let card = cardRepo.createCard(in: column, title: "Fix bug")

        let entity = try CardEntity(from: card)

        #expect(String(describing: entity.displayRepresentation).contains("Fix bug"))
    }

    @Test func queryByIDReturnsMatchingCards() async throws {
        let (persistence, _, cardRepo, column) = makeContext()
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let uuidA = try #require(a.id)
        let uuidB = try #require(b.id)

        let query = CardQuery(context: persistence.viewContext)
        let results = try await query.entities(for: [uuidA, uuidB])

        let titles = Set(results.map(\.title))
        #expect(titles == ["A", "B"])
    }

    @Test func suggestedEntitiesReturnsAllCardsSortedByTitle() async throws {
        let (persistence, _, cardRepo, column) = makeContext()
        _ = cardRepo.createCard(in: column, title: "Charlie")
        _ = cardRepo.createCard(in: column, title: "Alpha")
        _ = cardRepo.createCard(in: column, title: "Bravo")

        let query = CardQuery(context: persistence.viewContext)
        let results = try await query.suggestedEntities()

        #expect(results.map(\.title) == ["Alpha", "Bravo", "Charlie"])
    }
}
```

- [ ] **Step 2: Verify failing build**

Run: `xcodebuild ... build 2>&1 | grep "Cannot find 'CardEntity'" | head -1`
Expected: error referencing `CardEntity`.

- [ ] **Step 3: Implement `CardEntity`**

Create `FenixKanban/Features/Intents/CardEntity.swift`:

```swift
import AppIntents
import CoreData
import Foundation

struct CardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    static var defaultQuery = CardQuery()

    var id: UUID
    var title: String
    var cardDescription: String?
    var dueDate: Date?
    var isCompleted: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: UUID, title: String, cardDescription: String?, dueDate: Date?, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.cardDescription = cardDescription
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }

    init(from card: Card) throws {
        guard let id = card.id else {
            throw CardEntityError.missingID
        }
        self.id = id
        self.title = card.title ?? "Untitled Card"
        self.cardDescription = card.cardDescription
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
    }
}

enum CardEntityError: Error {
    case missingID
}
```

- [ ] **Step 4: Implement `CardQuery`**

Create `FenixKanban/Features/Intents/CardQuery.swift`:

```swift
import AppIntents
import CoreData

struct CardQuery: EntityQuery {
    private let context: NSManagedObjectContext

    init() {
        self.context = PersistenceController.shared.container.viewContext
    }

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func entities(for identifiers: [UUID]) async throws -> [CardEntity] {
        try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", identifiers)
            let cards = try context.fetch(request)
            return cards.compactMap { try? CardEntity(from: $0) }
        }
    }

    func suggestedEntities() async throws -> [CardEntity] {
        try await context.perform {
            let request = Card.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            let cards = try context.fetch(request)
            return cards.compactMap { try? CardEntity(from: $0) }
        }
    }
}
```

- [ ] **Step 5: Regen, run tests, build macOS**

Same commands as Task 2 step 5/6.
Expected: `Test run with 93 tests in 17 suites passed`, both builds succeed.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Intents/CardEntity.swift \
        FenixKanban/Features/Intents/CardQuery.swift \
        FenixKanbanTests/Intents/CardEntityTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): add CardEntity and CardQuery

Mirrors BoardEntity/BoardQuery for Card: id, title, cardDescription,
dueDate, isCompleted. Resolves entities by UUID and suggests all cards
sorted by title for Shortcuts pickers."
```

---

### Task 4: OpenBoardIntent + tests

**Files:**
- Create: `FenixKanban/Features/Intents/OpenBoardIntent.swift`
- Create: `FenixKanbanTests/Intents/OpenBoardIntentTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Intents/OpenBoardIntentTests.swift`:

```swift
import Testing
import AppIntents
import CoreData
@testable import FenixKanban

@Suite("Open Board Intent", .serialized)
@MainActor
struct OpenBoardIntentTests {

    private func setup() -> (PersistenceController, BoardRepository, NavigationModel) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let repo = BoardRepository(context: persistence.viewContext)
        let navigator = NavigationModel()
        return (persistence, repo, navigator)
    }

    @Test func performSelectsBoardOnNavigator() async throws {
        let (persistence, repo, navigator) = setup()
        let board = repo.createBoard(name: "Bug Triage")
        let entity = try BoardEntity(from: board)

        var intent = OpenBoardIntent()
        intent.board = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        _ = try await intent.perform()

        #expect(navigator.selectedBoardID == board.objectID)
    }

    @Test func performThrowsWhenBoardNoLongerExists() async throws {
        let (persistence, _, navigator) = setup()
        // Build an entity referencing a UUID that isn't in Core Data.
        let entity = BoardEntity(id: UUID(), name: "Ghost", colorHex: nil)

        var intent = OpenBoardIntent()
        intent.board = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            try await intent.perform()
        }
        #expect(navigator.selectedBoardID == nil)
    }
}
```

- [ ] **Step 2: Verify failing build**

Run: `xcodebuild ... build 2>&1 | grep "Cannot find 'OpenBoardIntent'" | head -1`
Expected: missing `OpenBoardIntent`.

- [ ] **Step 3: Implement `OpenBoardIntent`**

Create `FenixKanban/Features/Intents/OpenBoardIntent.swift`:

```swift
import AppIntents
import CoreData

struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens the specified board in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Board") var board: BoardEntity

    @Dependency private var navigator: NavigationModel
    @Dependency private var context: NSManagedObjectContext

    /// Test-only seam: lets tests pre-populate dependencies that the
    /// production runtime injects via `AppDependencyManager`.
    mutating func _injectDependencies(navigator: NavigationModel, context: NSManagedObjectContext) {
        self._$navigator.wrappedValue = navigator
        self._$context.wrappedValue = context
    }

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

**If `_$navigator.wrappedValue =` doesn't compile** (the `@Dependency` projected-value setter may be private in some App Intents versions), fall back to making the dependencies optional `var` with default-nil initializers and a single `_injectDependencies` method that assigns them directly — see Task 4 Step 7's "If the test seam doesn't compile" note.

- [ ] **Step 4: Regen, run tests**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild ... test 2>&1 | grep -E "Test run with|TEST" | tail -3
```
Expected: `Test run with 95 tests in 18 suites passed` (93 + 2 new), `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build macOS**

Same as prior tasks.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Intents/OpenBoardIntent.swift \
        FenixKanbanTests/Intents/OpenBoardIntentTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): add OpenBoardIntent

AppIntent that opens a board. @Dependency-injects NavigationModel
and the Core Data view context (registered at app launch). perform()
delegates to NavigationModel.openBoard and throws a needsValueError
if the board no longer exists. Test seam _injectDependencies(...)
bypasses the AppDependencyManager registration for unit tests."
```

- [ ] **Step 7: If the `@Dependency` test seam doesn't compile**

The `_$navigator.wrappedValue` setter is internal to the App Intents runtime in some Xcode versions. If Step 4 fails with `'_$navigator' is inaccessible` or similar, restructure:

```swift
struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens the specified board in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Board") var board: BoardEntity

    // Optional test seams; runtime resolves via AppDependencyManager.
    var navigatorOverride: NavigationModel?
    var contextOverride: NSManagedObjectContext?

    @Dependency private var navigator: NavigationModel
    @Dependency private var context: NSManagedObjectContext

    private var resolvedNavigator: NavigationModel { navigatorOverride ?? navigator }
    private var resolvedContext: NSManagedObjectContext { contextOverride ?? context }

    mutating func _injectDependencies(navigator: NavigationModel, context: NSManagedObjectContext) {
        self.navigatorOverride = navigator
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let opened = resolvedNavigator.openBoard(uuid: board.id, in: resolvedContext)
        if !opened {
            throw $board.needsValueError("That board no longer exists.")
        }
        return .result()
    }
}
```

This pattern works regardless of App Intents internal access modifiers and is the recommended fallback if you hit access issues.

---

### Task 5: OpenCardIntent + tests

**Files:**
- Create: `FenixKanban/Features/Intents/OpenCardIntent.swift`
- Create: `FenixKanbanTests/Intents/OpenCardIntentTests.swift`

Exact same shape as Task 4 but for `CardEntity` / `NavigationModel.openCard`. Use whichever dependency-injection pattern compiled cleanly in Task 4.

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/Intents/OpenCardIntentTests.swift`:

```swift
import Testing
import AppIntents
import CoreData
@testable import FenixKanban

@Suite("Open Card Intent", .serialized)
@MainActor
struct OpenCardIntentTests {

    private func setup() -> (PersistenceController, CardRepository, Column, NavigationModel) {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        return (persistence, cardRepo, column, NavigationModel())
    }

    @Test func performSelectsCardOnNavigator() async throws {
        let (persistence, cardRepo, column, navigator) = setup()
        let card = cardRepo.createCard(in: column, title: "Fix bug")
        let entity = try CardEntity(from: card)

        var intent = OpenCardIntent()
        intent.card = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        _ = try await intent.perform()

        #expect(navigator.selectedCardID == card.objectID)
    }

    @Test func performThrowsWhenCardNoLongerExists() async throws {
        let (persistence, _, _, navigator) = setup()
        let entity = CardEntity(id: UUID(), title: "Ghost", cardDescription: nil, dueDate: nil, isCompleted: false)

        var intent = OpenCardIntent()
        intent.card = entity
        intent._injectDependencies(navigator: navigator, context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            try await intent.perform()
        }
        #expect(navigator.selectedCardID == nil)
    }
}
```

- [ ] **Step 2: Implement `OpenCardIntent`**

Mirror the structure used in Task 4 (whichever variant compiled). The body is:

```swift
struct OpenCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Card"
    static var description = IntentDescription("Opens the specified card in FenixKanban.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Card") var card: CardEntity

    // dependencies + test seam (match Task 4's chosen pattern)
    // ...

    @MainActor
    func perform() async throws -> some IntentResult {
        let opened = resolvedNavigator.openCard(uuid: card.id, in: resolvedContext)
        if !opened {
            throw $card.needsValueError("That card no longer exists.")
        }
        return .result()
    }
}
```

- [ ] **Step 3: Regen, test, macOS build**

Expected: `Test run with 97 tests in 19 suites passed`, both builds succeed.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Intents/OpenCardIntent.swift \
        FenixKanbanTests/Intents/OpenCardIntentTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): add OpenCardIntent

Mirror of OpenBoardIntent for cards. Same dependency-injection
pattern as OpenBoardIntent and the same test seam."
```

---

### Task 6: FenixKanbanShortcuts (AppShortcutsProvider)

**Files:**
- Create: `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`

No tests — this is a static declaration the system parses at install time.

- [ ] **Step 1: Implement the provider**

Create `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`:

```swift
import AppIntents

struct FenixKanbanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: [
                "Open \(\.$board) in \(.applicationName)",
                "Show \(\.$board) in \(.applicationName)",
                "Go to \(\.$board) in \(.applicationName)"
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

- [ ] **Step 2: Regen + build (iOS + macOS)**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild ... build  # iOS
xcodebuild ... build  # macOS
```
Both expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite (regression check, no new tests)**

Expected: same 97 tests still pass.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Features/Intents/FenixKanbanShortcuts.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): register OpenBoard/OpenCard as App Shortcuts

AppShortcutsProvider exposes both intents to Siri and the Shortcuts
app with natural-language phrases. The Shortcuts app picks these up
on next launch after install."
```

---

### Task 7: Wire NavigationModel into FenixKanbanApp + ContentView

**Files:**
- Modify: `FenixKanban/FenixKanbanApp.swift`

This is glue. No new tests; existing 97 must continue to pass.

- [ ] **Step 1: Read the current `FenixKanbanApp.swift`**

Run: `cat FenixKanban/FenixKanbanApp.swift`

Confirm `ContentView` currently has `@State private var selectedBoardID: NSManagedObjectID?`.

- [ ] **Step 2: Replace `FenixKanban/FenixKanbanApp.swift` with the navigator-integrated version**

Edit so the file becomes:

```swift
import AppIntents
import CoreData
import StoreKit
import SwiftUI

@main
struct FenixKanbanApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var authService = AuthenticationService()
    @StateObject private var syncMonitor: SyncMonitor
    @State private var navigator = NavigationModel()

    init() {
        let monitor = SyncMonitor(container: PersistenceController.shared.container)
        _syncMonitor = StateObject(wrappedValue: monitor)

        // Register App Intents dependencies synchronously so cold-launch
        // from Siri / Shortcuts resolves them before any perform() runs.
        let viewContext = PersistenceController.shared.container.viewContext
        AppDependencyManager.shared.add(dependency: viewContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(navigator: navigator)
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(authService)
                .environmentObject(syncMonitor)
                .preferredColorScheme(.dark)
                .onAppear {
                    // NavigationModel is @MainActor-isolated so its
                    // registration has to happen here, not in init().
                    AppDependencyManager.shared.add(dependency: navigator)
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
                    NotificationService.shared.refreshAllReminders(context: persistence.viewContext)
                }
                .task {
                    for await result in Transaction.updates {
                        if case .verified(let transaction) = result {
                            await transaction.finish()
                        }
                    }
                }
        }
    }
}

struct ContentView: View {
    @Bindable var navigator: NavigationModel
    @EnvironmentObject var authService: AuthenticationService
    @EnvironmentObject var syncMonitor: SyncMonitor
    @Environment(\.managedObjectContext) private var context
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("hasSkippedAuth") private var hasSkippedAuth = false

    var body: some View {
        Group {
            if !authService.isAuthenticated && authService.userID == nil && !hasSkippedAuth {
                AuthView(viewModel: AuthViewModel(authService: authService))
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    BoardListView(context: context, selection: $navigator.selectedBoardID)
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                HStack(spacing: 12) {
                                    SyncStatusIndicator(status: syncMonitor.status)
                                    Button { showSettings = true } label: {
                                        Image(systemName: "gearshape")
                                    }
                                }
                            }
                        }
                } detail: {
                    if let boardID = navigator.selectedBoardID,
                       let board = try? context.existingObject(with: boardID) as? Board {
                        BoardView(board: board, context: context)
                            .adaptiveLayout()
                            .id(boardID)
                    } else {
                        EmptyStateView(
                            icon: "sidebar.squares.left",
                            title: "Select a Board",
                            message: "Choose a board from the sidebar"
                        )
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .sheet(isPresented: Binding(
                    get: { navigator.selectedCardID != nil },
                    set: { if !$0 { navigator.selectedCardID = nil } }
                )) {
                    if let cardID = navigator.selectedCardID,
                       let card = try? context.existingObject(with: cardID) as? Card {
                        CardDetailView(card: card, context: context)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(authService: authService, persistence: .shared)
                .environment(\.managedObjectContext, context)
        }
    }
}
```

Key changes:

- `import AppIntents` added.
- `@State private var navigator = NavigationModel()` added at the app level.
- `init()` registers `viewContext` as an `IntentDependency`.
- `.onAppear` registers `navigator` as an `IntentDependency` (deferred from `init()` because `NavigationModel` is `@MainActor` and `init()` isn't).
- `ContentView` gains a `@Bindable var navigator: NavigationModel` parameter.
- The existing `@State selectedBoardID` is removed; `BoardListView`'s selection binding and the detail-pane lookup both read from `navigator.selectedBoardID`.
- A new `.sheet(...)` watches `navigator.selectedCardID` and presents `CardDetailView` when an intent sets it.

- [ ] **Step 3: Regen, build iOS**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|BUILD" | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If the build fails, the most likely culprits are (a) `BoardListView`'s `selection:` parameter type or (b) `@Bindable` requiring an explicit observation import. Address inline rather than rolling back.

- [ ] **Step 4: Build macOS**

Same.

- [ ] **Step 5: Run full test suite**

Expected: `Test run with 97 tests in 19 suites passed`. (No new tests; this task only modifies app glue.) Any test failure here is a regression — debug before continuing.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): wire NavigationModel into app, register IntentDependencies

ContentView now reads board selection from a shared NavigationModel
@Bindable; the existing local @State selectedBoardID is removed.
FenixKanbanApp registers the Core Data view context (in init for
cold-launch correctness) and the NavigationModel (.onAppear, since
it's @MainActor) as IntentDependencies so OpenBoardIntent /
OpenCardIntent can @Dependency-inject them.

Adds a new sheet that watches navigator.selectedCardID and presents
CardDetailView when an intent (or future feature) sets it."
```

---

### Task 8: Manual verification — install + Shortcuts app

This task is read-only. Confirm the Shortcuts app surfaces the new actions.

- [ ] **Step 1: Boot the simulator and install**

```bash
xcrun simctl boot "iPhone 17" 2>&1 | head -1 || true
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app | head -1)
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl launch "iPhone 17" com.bluefenixproductions.FenixKanban
sleep 2
xcrun simctl terminate "iPhone 17" com.bluefenixproductions.FenixKanban
```

(Launching once then terminating gives the App Shortcuts indexer a chance to register the provider.)

- [ ] **Step 2: Open the Shortcuts app and search for FenixKanban**

Launch the Shortcuts app in the simulator (it's a system app, no install needed):

```bash
xcrun simctl launch "iPhone 17" com.apple.shortcuts
sleep 3
xcrun simctl io "iPhone 17" screenshot /tmp/fenixkanban-liquid-glass/04-shortcuts-app.png
```

Open the screenshot and:

- Search the app gallery for "FenixKanban".
- Confirm both **Open Board** and **Open Card** appear as actions.
- Tap "Open Board" → the parameter picker should list the user's actual boards (if any exist; if none, the picker shows an empty state).

- [ ] **Step 3: Verify via Siri (optional)**

If you have a populated database, invoke "Hey Siri, open Bug Triage in FenixKanban" — the app should launch and navigate to the matching board.

- [ ] **Step 4: No commit**

Verification only.

---

### Task 9: Update TDD_IMPLEMENTATION_STATUS.md

**Files:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md`

Per the repo rule.

- [ ] **Step 1: Append the new section**

Use the Edit tool to append at the end of the file. The current last line is approximately:

```
- **#4 App Intents + Core Spotlight:** see next section once scoped.
```

Edit with:

`old_string`:

```
- **#4 App Intents + Core Spotlight:** see next section once scoped.
```

`new_string`:

```
- **#4 App Intents + Core Spotlight:** see next section once scoped.

---

## 🪟 May 25, 2026 — App Intents MVP (follow-up #4, Spotlight cancelled)

App Intents adoption per
[`docs/superpowers/specs/2026-05-25-app-intents-mvp-design.md`](docs/superpowers/specs/2026-05-25-app-intents-mvp-design.md)
and executed via
[`docs/superpowers/plans/2026-05-25-app-intents-mvp.md`](docs/superpowers/plans/2026-05-25-app-intents-mvp.md).

**Core Spotlight integration was explicitly cancelled by user before implementation.**

**New code:**

- `FenixKanban/Core/Navigation/NavigationModel.swift`: `@Observable` `@MainActor` model with `selectedBoardID` / `selectedCardID`. `openBoard(uuid:in:)` / `openCard(uuid:in:)` look up managed objects by UUID and set the corresponding `objectID`. Returns false (without mutating) on miss so intents can throw a meaningful error.
- `FenixKanban/Features/Intents/BoardEntity.swift` + `BoardQuery.swift`: `AppEntity` representation of `Board` and its `EntityQuery` (fetches from `PersistenceController.shared.container.viewContext` by default, accepts an injected context for tests).
- `FenixKanban/Features/Intents/CardEntity.swift` + `CardQuery.swift`: same pattern for `Card`.
- `FenixKanban/Features/Intents/OpenBoardIntent.swift`: `AppIntent` with `openAppWhenRun = true`. `@Parameter(title: "Board") var board: BoardEntity`. `@Dependency`-injects `NavigationModel` and `NSManagedObjectContext`. Has a `_injectDependencies(navigator:context:)` test seam.
- `FenixKanban/Features/Intents/OpenCardIntent.swift`: parallel for cards.
- `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`: `AppShortcutsProvider` declaring both intents with natural-language phrases.

**Modified code:**

- `FenixKanban.FenixKanbanApp`: added `@State navigator = NavigationModel()`, registered `viewContext` as an `IntentDependency` in `init()` (synchronous for cold-launch), registered `navigator` in `.onAppear` (it's `@MainActor`).
- `FenixKanban.ContentView`: removed the local `@State selectedBoardID`; now reads selection from a `@Bindable navigator: NavigationModel`. Added a new sheet watching `navigator.selectedCardID` so intents can open cards.

**Tests:** 19 new tests across 5 suites — `NavigationModelTests` (5), `BoardEntityTests` (5), `CardEntityTests` (5), `OpenBoardIntentTests` (2), `OpenCardIntentTests` (2). Total: **97 tests in 19 suites** (up from 78 in 14). All `@MainActor` and `.serialized` (CoreData-touching).

**TDD compliance:** All five suites were written **red → green → refactor**. Each test file was committed in the same commit as the implementation it covers, but the failing-test-first sequence was followed during development.

**Manual verification:** Shortcuts app on iPhone 17 simulator shows both "Open Board" and "Open Card" actions; parameter pickers list the user's actual boards/cards.

**Deferred follow-ups (Standard tier):**

- `CreateCardIntent`, `CompleteCardIntent` (write intents)
- `FindCardIntent` (semantic query)
- `NSUserActivity` donations from `BoardView` and `CardView` so Spotlight learns usage patterns
- Core Spotlight indexing (the cancellation from this round can be reversed cheaply — the `AppEntity` scaffold makes it ~1 new file)
- `Label` as `AppEntity` (Full tier)
- Focus Filters (Full tier)
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "docs: record App Intents MVP in TDD status"
```

- [ ] **Step 3: Final verification**

```bash
git status     # working tree clean
git log --oneline -10  # confirm Tasks 1-9 commits all present
```

---

## Self-review notes

**Spec coverage:** every section of the spec maps to a task —
- `NavigationModel` → Task 1
- `BoardEntity` / `BoardQuery` → Task 2
- `CardEntity` / `CardQuery` → Task 3
- `OpenBoardIntent` → Task 4
- `OpenCardIntent` → Task 5
- `FenixKanbanShortcuts` → Task 6
- `FenixKanbanApp` integration → Task 7
- Acceptance criteria (Shortcuts app manual check) → Task 8
- Repo rule (TDD_IMPLEMENTATION_STATUS.md update) → Task 9.

**Placeholder scan:** no TBDs. Each step has either exact code or exact commands. The Task 4 fallback in Step 7 is an explicit branching plan for a known unknown (App Intents `@Dependency` internal access modifiers vary by Xcode version) — not a placeholder.

**Type consistency:** `BoardEntity.id` is `UUID`; `NavigationModel.openBoard(uuid:in:)` takes `UUID`; `BoardEntity(from: Board)` reads `board.id` which is `UUID?` and throws if nil. `BoardListView`'s existing `selection:` parameter is `Binding<NSManagedObjectID?>` and `navigator.selectedBoardID` is `NSManagedObjectID?` — types match.
