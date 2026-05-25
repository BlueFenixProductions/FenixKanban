# Golden Ticket Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single, scarce-by-convention "golden ticket" priority to FenixKanban — one boolean field on `Card`, gold-tinted Liquid Glass + ticket icon, floats to the top of its column, four toggle surfaces, plus App Intents for Siri / Shortcuts.

**Architecture:** A new `Card.isGolden` boolean attribute drives a composite sort in `Column.sortedCards` (golden cards above non-golden, then by `sortOrder`). Visual treatment swaps the tint in `CardView`'s existing `.glassEffect(.regular.tint(...))` and overlays a ticket SF Symbol. Toggle entry points: `CardDetailView` toolbar button, `CardView` context menu item, custom iOS `GoldenSwipeModifier`, and a `GoldZoneChip` drop target in the column header. App Intents (`ToggleGoldenIntent`, `FindGoldenCardsIntent`) mirror existing `OpenBoardIntent` / `OpenCardIntent` patterns.

**Tech Stack:** SwiftUI · CoreData + NSPersistentCloudKitContainer · Swift Testing (`@Test` / `#expect`) · App Intents · Liquid Glass (iOS 26 / macOS 26).

**Spec reference:** [docs/superpowers/specs/2026-05-25-golden-ticket-priority-design.md](../specs/2026-05-25-golden-ticket-priority-design.md) (committed in `1dcaad2`).

---

## File Structure

**New files:**
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 2.xcdatamodel/contents` — v2 CoreData model with `isGolden`.
- `FenixKanban/Components/GoldenSwipeModifier.swift` — iOS-only custom swipe modifier.
- `FenixKanban/Components/GoldZoneChip.swift` — gold drop target chip.
- `FenixKanban/Features/Intents/ToggleGoldenIntent.swift` — App Intent that toggles `isGolden`.
- `FenixKanban/Features/Intents/FindGoldenCardsIntent.swift` — App Intent that lists golden cards.
- `FenixKanbanTests/Models/CardGoldenTicketTests.swift` — attribute default + persistence.
- `FenixKanbanTests/Repositories/CardRepositoryGoldenSortTests.swift` — composite sort behavior.
- `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift` — `toggleGolden(for:)` / `toggleGolden(cardID:)`.
- `FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift` — intent perform + dialog.
- `FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift` — query + board filter.

**xcodegen note:** the `.xcodeproj` is synthesized from `project.yml` plus the source tree. **After creating any new file (test or source), run `xcodegen generate` before the next `xcodebuild` invocation**, otherwise the build/test won't see the new file. Modifying existing files needs no regen. Tasks 1, 3, 9, 10, 12, 13 each create new files — each commit should include the updated `FenixKanban.xcodeproj/project.pbxproj`.

**Modified files:**
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion` — point to v2.
- `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift` — composite sort in `Column.sortedCards`.
- `FenixKanban/Extensions/Color+CrossPlatform.swift` — gold colors + Increase-Contrast variants.
- `FenixKanban/Features/Board/BoardViewModel.swift` — `toggleGolden(for:)` and `toggleGolden(cardID:)`.
- `FenixKanban/Features/Card/CardDetailViewModel.swift` — `toggleGolden()` for the toolbar.
- `FenixKanban/Features/Card/CardView.swift` — gold tint + ticket overlay + context-menu item + swipe modifier.
- `FenixKanban/Features/Card/CardDetailView.swift` — toolbar toggle button.
- `FenixKanban/Features/Board/ColumnView.swift` — embed `GoldZoneChip` in the column header.
- `FenixKanban/Features/Intents/CardEntity.swift` — add `isGolden` field + subtitle.
- `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift` — two new `AppShortcut` entries.
- `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` — append `toggleGolden()` cases.
- `TDD_IMPLEMENTATION_STATUS.md` — append feature log + outstanding-items entry for the CloudKit Production schema deploy.

---

## Task 1: Add `isGolden` to CoreData model (v2)

Lightweight migration: new non-optional `Boolean` with `defaultValueString="NO"`. Create a sibling `.xcdatamodel` directory; flip `.xccurrentversion`.

**Files:**
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 2.xcdatamodel/contents`
- Modify: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`
- Create: `FenixKanbanTests/Models/CardGoldenTicketTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FenixKanbanTests/Models/CardGoldenTicketTests.swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card isGolden attribute", .serialized)
@MainActor
struct CardGoldenTicketTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = cardRepo.createCard(in: column, title: "T")
    }

    @Test("isGolden defaults to false on insert")
    func defaultIsFalse() {
        #expect(card.isGolden == false)
    }

    @Test("isGolden round-trips through save/fetch")
    func persistsAcrossSave() throws {
        card.isGolden = true
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.isGolden == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardGoldenTicketTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: build failure — `'Card' has no member 'isGolden'`.

- [ ] **Step 3: Create v2 model directory**

```bash
mkdir -p "FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 2.xcdatamodel"
```

- [ ] **Step 4: Write v2 contents file**

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="23231" systemVersion="24A335" minimumToolsVersion="Automatic" sourceLanguage="Swift" usedWithCloudKit="YES" userDefinedModelVersionIdentifier="">
    <entity name="Board" representedClassName="Board" syncable="YES" codeGenerationType="category">
        <attribute name="colorHex" optional="YES" attributeType="String"/>
        <attribute name="createdAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="id" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="modifiedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Board"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <relationship name="columns" optional="YES" toMany="YES" deletionRule="Cascade" destinationEntity="Column" inverseName="board" inverseEntity="Column"/>
    </entity>
    <entity name="Card" representedClassName="Card" syncable="YES" codeGenerationType="category">
        <attribute name="cardDescription" optional="YES" attributeType="String"/>
        <attribute name="createdAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="dueDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="id" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="isCompleted" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
        <attribute name="isGolden" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
        <attribute name="modifiedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="title" attributeType="String" defaultValueString="Untitled Card"/>
        <relationship name="column" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Column" inverseName="cards" inverseEntity="Column"/>
        <relationship name="label" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Label" inverseName="cards" inverseEntity="Label"/>
    </entity>
    <entity name="Column" representedClassName="Column" syncable="YES" codeGenerationType="category">
        <attribute name="colorHex" optional="YES" attributeType="String"/>
        <attribute name="createdAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="id" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="modifiedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Column"/>
        <attribute name="sortOrder" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <relationship name="board" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Board" inverseName="columns" inverseEntity="Board"/>
        <relationship name="cards" optional="YES" toMany="YES" deletionRule="Cascade" destinationEntity="Card" inverseName="column" inverseEntity="Card"/>
    </entity>
    <entity name="Label" representedClassName="Label" syncable="YES" codeGenerationType="category">
        <attribute name="colorHex" optional="YES" attributeType="String" defaultValueString="#808080"/>
        <attribute name="createdAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="id" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="name" attributeType="String" defaultValueString="Untitled Label"/>
        <relationship name="cards" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="Card" inverseName="label" inverseEntity="Card"/>
    </entity>
</model>
```

Write to: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 2.xcdatamodel/contents`

The only difference from v1 is the new `<attribute name="isGolden" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>` line on the `Card` entity.

- [ ] **Step 5: Flip `.xccurrentversion` to v2**

Replace the contents of `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>_XCCurrentVersionName</key>
	<string>FenixKanban 2.xcdatamodel</string>
</dict>
</plist>
```

- [ ] **Step 6: Regenerate xcodeproj (xcodegen will pick up the new model directory)**

```bash
xcodegen generate
```
Expected: `Created project at .../FenixKanban.xcodeproj`.

- [ ] **Step 7: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardGoldenTicketTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` (both `defaultIsFalse` and `persistsAcrossSave` pass).

- [ ] **Step 8: Commit**

```bash
git add "FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld" \
        FenixKanbanTests/Models/CardGoldenTicketTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(model): add Card.isGolden attribute (v2 lightweight migration)"
```

---

## Task 2: Composite sort — golden cards float to top of column

The actual sort site is `Column.sortedCards` in `NSManagedObject+Extensions.swift` (the spec mentions `CardRepository`, but `CardRepository.fetchCards(in:)` just returns `column.sortedCards`). Change the comparator here and the entire app picks up the new ordering for free.

**Files:**
- Modify: `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift:19-22`
- Create: `FenixKanbanTests/Repositories/CardRepositoryGoldenSortTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FenixKanbanTests/Repositories/CardRepositoryGoldenSortTests.swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card sort: golden floats to top", .serialized)
@MainActor
struct CardRepositoryGoldenSortTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let column: Column

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
    }

    private func makeCard(title: String, sortOrder: Int32, isGolden: Bool) -> Card {
        let card = cardRepo.createCard(in: column, title: title)
        card.sortOrder = sortOrder
        card.isGolden = isGolden
        try? persistence.viewContext.save()
        return card
    }

    @Test("Golden card with higher sortOrder still sorts above non-golden")
    func goldenFloatsAbove() {
        _ = makeCard(title: "A", sortOrder: 0, isGolden: false)
        _ = makeCard(title: "B", sortOrder: 1000, isGolden: true)
        _ = makeCard(title: "C", sortOrder: 2000, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["B", "A", "C"])
    }

    @Test("Manual reorder within golden group is preserved")
    func goldenInternalOrder() {
        _ = makeCard(title: "G1", sortOrder: 10, isGolden: true)
        _ = makeCard(title: "G2", sortOrder: 5, isGolden: true)
        _ = makeCard(title: "N1", sortOrder: 100, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["G2", "G1", "N1"])
    }

    @Test("All-non-golden behavior unchanged")
    func noGoldenSortsByOrder() {
        _ = makeCard(title: "X", sortOrder: 2, isGolden: false)
        _ = makeCard(title: "Y", sortOrder: 1, isGolden: false)
        _ = makeCard(title: "Z", sortOrder: 3, isGolden: false)
        let fetched = cardRepo.fetchCards(in: column).map { $0.title ?? "" }
        #expect(fetched == ["Y", "X", "Z"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardRepositoryGoldenSortTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: `goldenFloatsAbove` and `goldenInternalOrder` fail with `Expectation failed` (existing sort is sortOrder-only).

- [ ] **Step 3: Update `Column.sortedCards` to composite sort**

Replace lines 19-22 in `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift`:

```swift
extension Column {
    /// Cards sorted with golden first, then by sortOrder. Golden cards
    /// always visually outrank non-golden ones regardless of sortOrder.
    var sortedCards: [Card] {
        let set = cards as? Set<Card> ?? []
        return set.sorted { lhs, rhs in
            if lhs.isGolden != rhs.isGolden { return lhs.isGolden && !rhs.isGolden }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    var cardCount: Int {
        (cards as? Set<Card>)?.count ?? 0
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardRepositoryGoldenSortTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all three tests pass.

- [ ] **Step 5: Run the full suite to make sure nothing else broke**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift \
        FenixKanbanTests/Repositories/CardRepositoryGoldenSortTests.swift
git commit -m "feat(sort): float golden cards to the top of their column"
```

---

## Task 3: `BoardViewModel.toggleGolden(for:)` and `toggleGolden(cardID:)`

`BoardViewModel` already has card-mutation methods (`addCard`, `deleteCard`, `moveCard`). Add two toggle entry points: one taking a `Card` (for context menu / swipe in `CardView`), one taking a `UUID` (for the drop handler in `GoldZoneChip`).

**Files:**
- Modify: `FenixKanban/Features/Board/BoardViewModel.swift`
- Create: `FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BoardViewModel golden toggle", .serialized)
@MainActor
struct BoardViewModelGoldenTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let board: Board
    let column: Column
    let viewModel: BoardViewModel

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        board = boardRepo.createBoard(name: "B")
        column = boardRepo.createColumn(in: board, name: "C")
        viewModel = BoardViewModel(board: board, context: persistence.viewContext)
    }

    @Test("toggleGolden(for:) flips state and bumps modifiedAt")
    func toggleByCardFlips() async throws {
        let card = cardRepo.createCard(in: column, title: "T")
        let before = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)  // ensure modifiedAt advances

        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == true)
        #expect((card.modifiedAt ?? .distantPast) > (before ?? .distantPast))

        viewModel.toggleGolden(for: card)
        #expect(card.isGolden == false)
    }

    @Test("toggleGolden(cardID:) finds and flips the right card")
    func toggleByIDFlips() {
        let card = cardRepo.createCard(in: column, title: "T")
        let uuid = card.id!
        viewModel.toggleGolden(cardID: uuid)
        #expect(card.isGolden == true)
    }

    @Test("toggleGolden(cardID:) is a no-op for unknown UUID")
    func toggleByIDIgnoresUnknown() {
        let card = cardRepo.createCard(in: column, title: "T")
        viewModel.toggleGolden(cardID: UUID())
        #expect(card.isGolden == false)
    }

    @Test("Toggling a non-golden card lifts it above non-golden siblings")
    func toggleReorders() {
        let a = cardRepo.createCard(in: column, title: "A")
        let b = cardRepo.createCard(in: column, title: "B")
        let c = cardRepo.createCard(in: column, title: "C")
        // a < b < c by sortOrder

        viewModel.toggleGolden(for: c)
        let titles = column.sortedCards.map { $0.title ?? "" }
        #expect(titles == ["C", "A", "B"])
        _ = (a, b)  // silence unused warnings
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/BoardViewModelGoldenTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile failure — `'BoardViewModel' has no member 'toggleGolden'`.

- [ ] **Step 3: Add the two toggle methods to `BoardViewModel`**

Append, just before the existing `observeChanges()` private function (around line 107 in `FenixKanban/Features/Board/BoardViewModel.swift`):

```swift
    func toggleGolden(for card: Card) {
        card.isGolden.toggle()
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? context.save()
        refreshColumns()
    }

    func toggleGolden(cardID: UUID) {
        let request = Card.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", cardID as CVarArg)
        request.fetchLimit = 1
        guard let card = try? context.fetch(request).first else { return }
        toggleGolden(for: card)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/BoardViewModelGoldenTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Board/BoardViewModel.swift \
        FenixKanbanTests/ViewModels/BoardViewModelGoldenTests.swift
git commit -m "feat(viewmodel): BoardViewModel.toggleGolden(for:/cardID:)"
```

---

## Task 4: `CardDetailViewModel.toggleGolden()`

The `CardDetailView` toolbar button (Task 6) will call this. Mirrors the small mutation methods already on `CardDetailViewModel` (`clearDueDate`, `clearLabel`, etc.).

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Append the failing test**

Add to the bottom of `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`, inside the existing `CardDetailViewModelTests` struct:

```swift
    @Test("toggleGolden flips isGolden and updates modifiedAt")
    func toggleGoldenFlips() async throws {
        #expect(card.isGolden == false)
        let before = card.modifiedAt
        try? await Task.sleep(nanoseconds: 2_000_000)

        viewModel.toggleGolden()
        #expect(card.isGolden == true)
        #expect((card.modifiedAt ?? .distantPast) > (before ?? .distantPast))

        viewModel.toggleGolden()
        #expect(card.isGolden == false)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardDetailViewModelTests/toggleGoldenFlips' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile failure — `'CardDetailViewModel' has no member 'toggleGolden'`.

- [ ] **Step 3: Add `toggleGolden()` to `CardDetailViewModel`**

Append before the closing brace of the `CardDetailViewModel` class:

```swift
    func toggleGolden() {
        card.isGolden.toggle()
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? context.save()
        objectWillChange.send()
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/CardDetailViewModelTests/toggleGoldenFlips' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: test passes.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailViewModel.swift \
        FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift
git commit -m "feat(viewmodel): CardDetailViewModel.toggleGolden()"
```

---

## Task 5: Gold colors + Increase-Contrast variants

`Color+CrossPlatform.swift` already namespaces project colors. Add the gold pair and high-contrast siblings.

**Files:**
- Modify: `FenixKanban/Extensions/Color+CrossPlatform.swift`
- Modify: `FenixKanbanTests/Extensions/ColorCrossPlatformTests.swift`

- [ ] **Step 1: Append failing tests**

Add to `FenixKanbanTests/Extensions/ColorCrossPlatformTests.swift`, inside the `ColorCrossPlatformTests` struct:

```swift
    @Test func goldenTicketResolves() {
        #expect(Color.goldenTicket != Color.clear)
    }

    @Test func goldenTicketIconResolves() {
        #expect(Color.goldenTicketIcon != Color.clear)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/ColorCrossPlatformTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile failure — `'Color' has no member 'goldenTicket'`.

- [ ] **Step 3: Add the colors**

Append to `FenixKanban/Extensions/Color+CrossPlatform.swift`, inside the `extension Color { ... }` block:

```swift
    // MARK: - Golden Ticket Priority

    /// Warm gold used as the .glassEffect tint for cards marked golden.
    static var goldenTicket: Color {
        if Self.shouldUseIncreasedContrast {
            return Color(red: 0.99, green: 0.82, blue: 0.20)  // deeper gold
        }
        return Color(red: 0.95, green: 0.78, blue: 0.20)
    }

    /// Foreground used for the ticket icon overlay and inline gold accents.
    /// Darker than `.goldenTicket` so it reads on top of the tinted glass.
    static var goldenTicketIcon: Color {
        if Self.shouldUseIncreasedContrast {
            return Color(red: 0.35, green: 0.22, blue: 0.0)
        }
        return Color(red: 0.55, green: 0.40, blue: 0.05)
    }

    private static var shouldUseIncreasedContrast: Bool {
        #if os(iOS)
        return UIAccessibility.isDarkerSystemColorsEnabled
        #elseif os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #else
        return false
        #endif
    }
```

Also add platform imports at the top of the file if not already present:

```swift
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/ColorCrossPlatformTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Extensions/Color+CrossPlatform.swift \
        FenixKanbanTests/Extensions/ColorCrossPlatformTests.swift
git commit -m "feat(color): add goldenTicket + goldenTicketIcon with Increase-Contrast"
```

---

## Task 6: Visual treatment in `CardView` (golden tint + ticket icon overlay)

Swap the existing `glassTint` computed property to return `.goldenTicket` when the card is golden, and overlay a ticket SF Symbol in the top-leading corner.

**Files:**
- Modify: `FenixKanban/Features/Card/CardView.swift`

This task has no automated test (Liquid Glass rendering can't be asserted programmatically). Verification is manual on macOS.

- [ ] **Step 1: Modify `glassTint` and add the overlay**

In `FenixKanban/Features/Card/CardView.swift`, replace the existing `glassTint` computed property (around line 7) with:

```swift
    private var glassTint: Color {
        if card.isGolden {
            return .goldenTicket
        }
        return columnColor?.opacity(0.18) ?? .clear
    }
```

Find the existing `.glassEffect(.regular.tint(glassTint), in: .rect(cornerRadius: 8))` line (around line 41) and add the ticket overlay *immediately after* the existing `.overlay { ... strokeBorder ... }` block (keep the existing stroke; just add a second overlay):

```swift
        .overlay(alignment: .topLeading) {
            if card.isGolden {
                Image(systemName: "ticket.fill")
                    .imageScale(.medium)
                    .foregroundStyle(Color.goldenTicketIcon)
                    .padding(8)
                    .accessibilityLabel("Golden ticket priority")
                    .accessibilityAddTraits(.isHeader)
            }
        }
```

- [ ] **Step 2: Build for macOS to confirm no compile errors**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build for iOS Simulator**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Open the freshly built macOS .app from `~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug/FenixKanban.app`. Create a card, then in the LLDB REPL or via the next task's toolbar (skip ahead temporarily by setting `card.isGolden = true` in code), confirm:

- Card body shows warm gold via Liquid Glass tint (not flat color — it should refract over backgrounds).
- Ticket icon appears in top-leading corner, darker gold.

If you can't toggle in the UI yet, manual verification can be deferred until Task 7 lands (the toolbar button gives the easiest in-app toggle).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Card/CardView.swift
git commit -m "feat(ui): gold-tinted glass + ticket-icon overlay on golden cards"
```

---

## Task 7: `CardDetailView` toolbar toggle button (Fizzy match)

Adds the ticket icon button at top-leading in the open card sheet — Fizzy's primary toggle location.

**Files:**
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`

No automated test (toolbar rendering is manual).

- [ ] **Step 1: Locate the existing toolbar in `CardDetailView`**

Open `FenixKanban/Features/Card/CardDetailView.swift` and find the `.toolbar { ... }` modifier on the form body. (If there isn't one yet, add one above any existing `.sheet` / `.navigationTitle` modifiers.)

- [ ] **Step 2: Add the toggle `ToolbarItem`**

`CardDetailView`'s init already accepts a `card: Card` parameter (used to build the `@StateObject` view model). Store that `card` as a property on the view (`let card: Card`) if it isn't already, then reference it from the toolbar. `viewModel.toggleGolden()` (Task 4) mutates the same `Card` instance — SwiftUI re-renders via `viewModel.objectWillChange.send()` inside `toggleGolden()`.

Inside the `.toolbar` block:

```swift
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.toggleGolden()
                } label: {
                    Image(systemName: card.isGolden ? "ticket.fill" : "ticket")
                }
                .tint(card.isGolden ? Color.goldenTicketIcon : .primary)
                .accessibilityLabel(card.isGolden ? "Remove golden ticket" : "Mark as golden ticket")
                .accessibilityHint("Promotes this card to the top of the column.")
            }
```

**Note on placement:** `.topBarLeading` works on iOS 14+. On macOS the placement falls back to `.navigation` automatically.

- [ ] **Step 3: Build for both platforms**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: `** BUILD SUCCEEDED **` on both.

- [ ] **Step 4: Manual verification**

Run the macOS app. Open a card. Click the ticket icon in the toolbar: card should turn gold, ticket icon should switch to `ticket.fill`, dismissing the sheet should show the card floated to the top of its column.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Card/CardDetailView.swift
git commit -m "feat(ui): toolbar ticket button toggles card golden state"
```

---

## Task 8: Context menu item on `CardView`

Adds "Mark as Golden" / "Remove Golden Ticket" to the context menu (right-click on macOS, long-press on iOS).

**Files:**
- Modify: `FenixKanban/Features/Card/CardView.swift`
- Modify: `FenixKanban/Features/Board/ColumnView.swift` (if context-menu lives there for cards) — *check first*.

No automated test.

- [ ] **Step 1: Find the existing `.contextMenu` on cards**

```bash
grep -rn "contextMenu" --include="*.swift" FenixKanban/Features/Card FenixKanban/Features/Board | head
```

If there's no existing context menu on the card row, add one. If there is one, you'll be inserting the new button at the top.

- [ ] **Step 2: Add an `onToggleGolden` closure to `CardView`**

`CardView` doesn't hold a reference to `BoardViewModel`. Pass a closure from `ColumnView` (which has the view model) into each `CardView`, matching the existing `onDropCard` closure pattern. This same closure will be reused by Task 9's swipe modifier.

In `FenixKanban/Features/Card/CardView.swift`, add to the struct's properties (alongside `card` and `columnColor`):

```swift
    var onToggleGolden: (Card) -> Void = { _ in }
```

Then attach the context menu to the outermost card view (alongside `.glassEffect` / `.draggable` / the new overlay from Task 6):

```swift
        .contextMenu {
            Button {
                onToggleGolden(card)
            } label: {
                SwiftUI.Label(
                    card.isGolden ? "Remove Golden Ticket" : "Mark as Golden",
                    systemImage: card.isGolden ? "ticket.slash" : "ticket"
                )
            }
            // ...existing context menu items go below this one
        }
```

- [ ] **Step 3: Wire the closure from `ColumnView`**

In `FenixKanban/Features/Board/ColumnView.swift`, find each call site that constructs `CardView(card: card, columnColor: columnColor)` (there are two — the main `.draggable` row and the `.dropDestination` preview). Add the closure argument:

```swift
                CardView(card: card, columnColor: columnColor, onToggleGolden: { viewModel.toggleGolden(for: $0) })
```

- [ ] **Step 4: Build both platforms**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: both succeed.

- [ ] **Step 5: Manual verification**

Run macOS app. Right-click a card → "Mark as Golden" should be the top item. Click it; the card turns gold and floats up. Right-click again → "Remove Golden Ticket". Click; card returns to non-golden.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Card/CardView.swift FenixKanban/Features/Board/ColumnView.swift
git commit -m "feat(ui): context-menu toggle for golden ticket"
```

---

## Task 9: `GoldenSwipeModifier` — iOS-only custom swipe

`.swipeActions` is List-only; cards live in a `LazyVStack` (so the column's drag/drop works). Custom drag-gesture-based swipe modifier instead. Scoped behind `#if os(iOS)`.

**Files:**
- Create: `FenixKanban/Components/GoldenSwipeModifier.swift`
- Modify: `FenixKanban/Features/Card/CardView.swift` (apply the modifier)

No automated test (gesture playback requires UI testing infrastructure not yet set up).

- [ ] **Step 1: Create the swipe modifier**

Write to `FenixKanban/Components/GoldenSwipeModifier.swift`:

```swift
import SwiftUI

#if os(iOS)
/// Trailing-edge horizontal-swipe gesture that reveals a gold pill
/// button. iOS-only — SwiftUI's `.swipeActions` only works inside
/// `List`, and FenixKanban's cards live in a `LazyVStack`.
struct GoldenSwipeModifier: ViewModifier {
    let isGolden: Bool
    let onToggle: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isRevealed = false

    private let revealThreshold: CGFloat = -80
    private let buttonWidth: CGFloat = 96

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                onToggle()
                close()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: isGolden ? "ticket.slash" : "ticket.fill")
                        .font(.title3)
                    Text(isGolden ? "Remove" : "Golden")
                        .font(.crossPlatformCaption2)
                }
                .foregroundStyle(Color.goldenTicketIcon)
                .frame(width: buttonWidth, maxHeight: .infinity)
                .background(Color.goldenTicket)
            }
            .opacity(isRevealed ? 1 : 0)
            .accessibilityHidden(!isRevealed)

            content
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Only respond to mostly-horizontal drags so
                            // we don't fight the column's vertical scroll
                            // or the card's long-press drag-and-drop.
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else {
                                return
                            }
                            dragOffset = min(0, value.translation.width)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if dragOffset < revealThreshold {
                                    dragOffset = -buttonWidth
                                    isRevealed = true
                                } else {
                                    close()
                                }
                            }
                        }
                )
        }
        .clipped()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = 0
            isRevealed = false
        }
    }
}

extension View {
    func goldenSwipe(isGolden: Bool, onToggle: @escaping () -> Void) -> some View {
        self.modifier(GoldenSwipeModifier(isGolden: isGolden, onToggle: onToggle))
    }
}
#else
extension View {
    /// No-op on macOS — swipe-row pattern is iOS-only.
    func goldenSwipe(isGolden: Bool, onToggle: @escaping () -> Void) -> some View {
        self
    }
}
#endif
```

- [ ] **Step 2: Apply the modifier to `CardView`**

Task 8 already added an `onToggleGolden: (Card) -> Void` closure parameter to `CardView`. Reuse it. In `FenixKanban/Features/Card/CardView.swift`, on the outermost view of the card body (the same view that has `.glassEffect` and `.draggable`), append:

```swift
        .goldenSwipe(isGolden: card.isGolden) {
            onToggleGolden(card)
        }
```

No changes needed to `ColumnView` — the closure is already passed in (Task 8 Step 3).

- [ ] **Step 3: Build both platforms**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: both succeed.

- [ ] **Step 4: Manual verification on iOS Simulator**

```bash
xcrun simctl install booted "$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app | head -1)"
xcrun simctl launch booted com.bluefenixproductions.FenixKanban
```

In the simulator: swipe a card left ~80pt → gold "Mark Golden" pill reveals. Tap → card turns gold and snaps back. Long-press a card (the existing card-drag interaction) should still trigger drag, not swipe — swipe is direction-locked to horizontal. Verify both gestures coexist; tune `minimumDistance` or the 1.5× direction-check ratio in the modifier if a conflict appears.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Components/GoldenSwipeModifier.swift \
        FenixKanban/Features/Card/CardView.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(ui): iOS swipe gesture reveals golden toggle"
```

---

## Task 10: `GoldZoneChip` drop target

A gold-tinted capsule with a ticket icon. Lives inline in the column header (no separate `ColumnHeaderView` extraction). Always visible; accepts a `String` (card UUID) drop matching the existing `.draggable(card.id?.uuidString)` payload.

**Files:**
- Create: `FenixKanban/Components/GoldZoneChip.swift`
- Modify: `FenixKanban/Features/Board/ColumnView.swift` (embed in header HStack)

No automated test for the drop interaction itself — `BoardViewModel.toggleGolden(cardID:)` (already tested in Task 3) is what it calls.

- [ ] **Step 1: Create the chip component**

Write to `FenixKanban/Components/GoldZoneChip.swift`:

```swift
import SwiftUI

/// A small gold-tinted Liquid Glass capsule shown in every column
/// header. Accepts a drag of a card UUID string and forwards it to the
/// closure, which toggles `isGolden` on the matching card.
///
/// Always visible (not show-only-during-drag) for discoverability and
/// to avoid the SwiftUI "is-a-drag-in-flight" plumbing.
struct GoldZoneChip: View {
    let onDropCardID: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        Image(systemName: "ticket.fill")
            .imageScale(.small)
            .foregroundStyle(Color.goldenTicketIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(
                .regular.tint(isTargeted ? Color.goldenTicket : Color.goldenTicket.opacity(0.5)),
                in: .capsule
            )
            .dropDestination(for: String.self) { items, _ in
                guard let uuidString = items.first else { return false }
                onDropCardID(uuidString)
                return true
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel("Drop a card here to mark it golden")
            .accessibilityAddTraits(.isButton)
    }
}
```

- [ ] **Step 2: Embed the chip in `ColumnView`'s header**

In `FenixKanban/Features/Board/ColumnView.swift`, find the column header `HStack` (around line 23-44 — the one containing the colored circle, name, count badge, `Spacer()`, and Menu). Add the chip just before the `Menu { ... }`:

```swift
                GoldZoneChip(onDropCardID: { uuidString in
                    guard let uuid = UUID(uuidString: uuidString) else { return }
                    viewModel.toggleGolden(cardID: uuid)
                })
```

So the header order is: circle, name, count, `Spacer()`, `GoldZoneChip`, `Menu`.

- [ ] **Step 3: Build both platforms**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```
Expected: both succeed.

- [ ] **Step 4: Manual verification on macOS**

Run macOS app. Each column header should show a gold ticket chip near the trailing edge. Drag a card by its long-press handle and drop it on the chip in its own column: card becomes golden, floats to the top. Dragging onto a chip in a *different* column should also mark golden (the drop handler doesn't reassign columns — it toggles in place; this is fine).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Components/GoldZoneChip.swift \
        FenixKanban/Features/Board/ColumnView.swift
git commit -m "feat(ui): gold drop-zone chip in column header"
```

---

## Task 11: Extend `CardEntity` with `isGolden`

Surfaces gold state in any context where a `CardEntity` is returned by an App Intent.

**Files:**
- Modify: `FenixKanban/Features/Intents/CardEntity.swift`

- [ ] **Step 1: Add the field and update `init(from:)`**

Replace the existing struct in `FenixKanban/Features/Intents/CardEntity.swift`:

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
    var isGolden: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: isGolden ? "Golden ticket" : nil
        )
    }

    init(id: UUID, title: String, cardDescription: String?, dueDate: Date?, isCompleted: Bool, isGolden: Bool) {
        self.id = id
        self.title = title
        self.cardDescription = cardDescription
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.isGolden = isGolden
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
        self.isGolden = card.isGolden
    }
}

enum CardEntityError: Error {
    case missingID
}
```

- [ ] **Step 2: Build to ensure nothing downstream breaks**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -5
```
Expected: `** BUILD SUCCEEDED **`. If any callers of `CardEntity.init(id:title:...)` exist outside `init(from:)`, the compiler will surface them (none today by grep).

- [ ] **Step 3: Commit**

```bash
git add FenixKanban/Features/Intents/CardEntity.swift
git commit -m "feat(intents): expose isGolden on CardEntity"
```

---

## Task 12: `ToggleGoldenIntent` App Intent

**Files:**
- Create: `FenixKanban/Features/Intents/ToggleGoldenIntent.swift`
- Create: `FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift
import Testing
import CoreData
import Foundation
import AppIntents
@testable import FenixKanban

@Suite("ToggleGoldenIntent", .serialized)
@MainActor
struct ToggleGoldenIntentTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        card = cardRepo.createCard(in: column, title: "Pay rent")
    }

    @Test("perform() flips isGolden and returns the updated entity")
    func performToggles() async throws {
        var intent = ToggleGoldenIntent()
        intent.card = try CardEntity(from: card)
        intent._injectDependencies(context: persistence.viewContext)

        let result = try await intent.perform()
        #expect(result.value?.isGolden == true)

        let result2 = try await intent.perform()
        #expect(result2.value?.isGolden == false)
    }

    @Test("perform() throws needsValueError when card no longer exists")
    func performMissingCardThrows() async throws {
        var intent = ToggleGoldenIntent()
        intent.card = CardEntity(id: UUID(), title: "Ghost", cardDescription: nil, dueDate: nil, isCompleted: false, isGolden: false)
        intent._injectDependencies(context: persistence.viewContext)

        await #expect(throws: (any Error).self) {
            _ = try await intent.perform()
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/ToggleGoldenIntentTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile failure — `cannot find 'ToggleGoldenIntent' in scope`.

- [ ] **Step 3: Write the intent**

Write to `FenixKanban/Features/Intents/ToggleGoldenIntent.swift`:

```swift
import AppIntents
import CoreData

struct ToggleGoldenIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Golden Ticket"
    static var description = IntentDescription(
        "Marks or unmarks a card as golden — promotes it to the top of its column."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Card") var card: CardEntity

    // Optional test seam. Runtime resolves via AppDependencyManager.
    var contextOverride: NSManagedObjectContext?

    @Dependency private var context: NSManagedObjectContext

    private var resolvedContext: NSManagedObjectContext {
        contextOverride ?? context
    }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<CardEntity> {
        let id = card.id
        let context = resolvedContext

        let updated: Card = try await context.perform {
            let request = Card.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let card = try context.fetch(request).first else {
                throw $card.needsValueError("That card no longer exists.")
            }
            card.isGolden.toggle()
            card.modifiedAt = Date()
            card.column?.modifiedAt = Date()
            card.column?.board?.modifiedAt = Date()
            try context.save()
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

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/ToggleGoldenIntentTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Intents/ToggleGoldenIntent.swift \
        FenixKanbanTests/Intents/ToggleGoldenIntentTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): ToggleGoldenIntent for Siri / Shortcuts"
```

---

## Task 13: `FindGoldenCardsIntent` + AppShortcut registrations

Returns a `[CardEntity]`, optionally scoped to one board. Plus the two `AppShortcut` registrations so Siri picks up the new actions.

**Files:**
- Create: `FenixKanban/Features/Intents/FindGoldenCardsIntent.swift`
- Create: `FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift`
- Modify: `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift
import Testing
import CoreData
import Foundation
import AppIntents
@testable import FenixKanban

@Suite("FindGoldenCardsIntent", .serialized)
@MainActor
struct FindGoldenCardsIntentTests {
    let persistence: PersistenceController
    let boardRepo: BoardRepository
    let cardRepo: CardRepository

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        boardRepo = BoardRepository(context: persistence.viewContext)
        cardRepo = CardRepository(context: persistence.viewContext)
    }

    private func makeCard(in column: Column, title: String, golden: Bool) -> Card {
        let card = cardRepo.createCard(in: column, title: title)
        card.isGolden = golden
        try? persistence.viewContext.save()
        return card
    }

    @Test("Without a board param, returns all golden cards across boards")
    func allBoards() async throws {
        let bA = boardRepo.createBoard(name: "A")
        let cA = boardRepo.createColumn(in: bA, name: "C")
        let bB = boardRepo.createBoard(name: "B")
        let cB = boardRepo.createColumn(in: bB, name: "C")
        _ = makeCard(in: cA, title: "A-Gold", golden: true)
        _ = makeCard(in: cA, title: "A-Plain", golden: false)
        _ = makeCard(in: cB, title: "B-Gold", golden: true)

        var intent = FindGoldenCardsIntent()
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        let titles = Set(result.value?.map(\.title) ?? [])
        #expect(titles == ["A-Gold", "B-Gold"])
    }

    @Test("With a board param, scopes results to that board")
    func boardScoped() async throws {
        let bA = boardRepo.createBoard(name: "A")
        let cA = boardRepo.createColumn(in: bA, name: "C")
        let bB = boardRepo.createBoard(name: "B")
        let cB = boardRepo.createColumn(in: bB, name: "C")
        _ = makeCard(in: cA, title: "A-Gold", golden: true)
        _ = makeCard(in: cB, title: "B-Gold", golden: true)

        var intent = FindGoldenCardsIntent()
        intent.board = try BoardEntity(from: bA)
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        let titles = result.value?.map(\.title) ?? []
        #expect(titles == ["A-Gold"])
    }

    @Test("Empty when no golden cards exist")
    func emptyResult() async throws {
        let b = boardRepo.createBoard(name: "A")
        let c = boardRepo.createColumn(in: b, name: "C")
        _ = makeCard(in: c, title: "P", golden: false)

        var intent = FindGoldenCardsIntent()
        intent._injectDependencies(context: persistence.viewContext)
        let result = try await intent.perform()
        #expect((result.value ?? []).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/FindGoldenCardsIntentTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile failure — `cannot find 'FindGoldenCardsIntent' in scope`.

- [ ] **Step 3: Write the intent**

Write to `FenixKanban/Features/Intents/FindGoldenCardsIntent.swift`:

```swift
import AppIntents
import CoreData

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

    private var resolvedContext: NSManagedObjectContext {
        contextOverride ?? context
    }

    mutating func _injectDependencies(context: NSManagedObjectContext) {
        self.contextOverride = context
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        let boardID = board?.id
        let context = resolvedContext

        let entities: [CardEntity] = try await context.perform {
            let request = Card.fetchRequest()
            if let boardID {
                request.predicate = NSPredicate(
                    format: "isGolden == YES AND column.board.id == %@",
                    boardID as CVarArg
                )
            } else {
                request.predicate = NSPredicate(format: "isGolden == YES")
            }
            request.sortDescriptors = [
                NSSortDescriptor(key: "modifiedAt", ascending: false)
            ]
            return try context.fetch(request).compactMap { try? CardEntity(from: $0) }
        }
        return .result(value: entities)
    }
}
```

- [ ] **Step 4: Register both new intents in `FenixKanbanShortcuts`**

Replace the contents of `FenixKanban/Features/Intents/FenixKanbanShortcuts.swift`:

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
        AppShortcut(
            intent: ToggleGoldenIntent(),
            phrases: [
                "Toggle golden ticket in \(.applicationName)",
                "Mark the golden ticket in \(.applicationName)"
            ],
            shortTitle: "Toggle Golden",
            systemImageName: "ticket.fill"
        )
        AppShortcut(
            intent: FindGoldenCardsIntent(),
            phrases: [
                "Find golden cards in \(.applicationName)",
                "Show my golden tickets in \(.applicationName)"
            ],
            shortTitle: "Find Golden Cards",
            systemImageName: "ticket"
        )
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -only-testing 'FenixKanbanTests/FindGoldenCardsIntentTests' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all three tests pass.

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Features/Intents/FindGoldenCardsIntent.swift \
        FenixKanban/Features/Intents/FenixKanbanShortcuts.swift \
        FenixKanbanTests/Intents/FindGoldenCardsIntentTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "feat(intents): FindGoldenCardsIntent + register both shortcuts"
```

---

## Task 14: Update `TDD_IMPLEMENTATION_STATUS.md` + add release checklist item

Final wrap. Logs the feature, records the CloudKit Production schema deploy as an outstanding release-checklist item.

**Files:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md`

- [ ] **Step 1: Append the feature log entry**

Append to the bottom of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown

---

## 🎟️ 2026-05-25 — Golden Ticket Priority

Implements the design in `docs/superpowers/specs/2026-05-25-golden-ticket-priority-design.md`. Fizzy.do-inspired single-flag priority: `Card.isGolden` boolean, composite sort floats golden cards to the top of their column, tinted Liquid Glass + ticket icon visual, four toggle surfaces (`CardDetailView` toolbar / `CardView` context menu / iOS `GoldenSwipeModifier` / `GoldZoneChip` drop target), and App Intents (`ToggleGoldenIntent` + `FindGoldenCardsIntent`) wired into `FenixKanbanShortcuts`.

**TDD phases (each its own commit):**

1. `feat(model): add Card.isGolden attribute (v2 lightweight migration)` — `CardGoldenTicketTests`
2. `feat(sort): float golden cards to the top of their column` — `CardRepositoryGoldenSortTests`
3. `feat(viewmodel): BoardViewModel.toggleGolden(for:/cardID:)` — `BoardViewModelGoldenTests`
4. `feat(viewmodel): CardDetailViewModel.toggleGolden()` — appended to `CardDetailViewModelTests`
5. `feat(color): add goldenTicket + goldenTicketIcon with Increase-Contrast` — appended to `ColorCrossPlatformTests`
6. `feat(ui): gold-tinted glass + ticket-icon overlay on golden cards`
7. `feat(ui): toolbar ticket button toggles card golden state`
8. `feat(ui): context-menu toggle for golden ticket`
9. `feat(ui): iOS swipe gesture reveals golden toggle`
10. `feat(ui): gold drop-zone chip in column header`
11. `feat(intents): expose isGolden on CardEntity`
12. `feat(intents): ToggleGoldenIntent for Siri / Shortcuts` — `ToggleGoldenIntentTests`
13. `feat(intents): FindGoldenCardsIntent + register both shortcuts` — `FindGoldenCardsIntentTests`

**Manual verification still needed:**

- Two-device CloudKit round-trip (mark on device A, observe on device B).
- VoiceOver + Increase Contrast on both platforms per `docs/accessibility-walkthrough.md`.
- iPhone Simulator: confirm `GoldenSwipeModifier` and the existing `.draggable` long-press coexist.

**Outstanding release checklist item:**

- [ ] **Before App Store submission:** Open CloudKit Dashboard → Container `iCloud.com.bluefenixproductions.FenixKanban` → Schema → Deploy Schema Changes to Production. Without this step, `isGolden` sync breaks for App Store users until the dashboard step happens. Sync resumes silently once promoted.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "docs: log golden ticket implementation + CloudKit deploy checklist"
```

---

## Final integration check

After all 14 tasks land, run one full suite + dual-platform build:

```bash
xcodebuild test -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3

xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)" | head -3
```

All three should report success. If any of the existing CloudKit-in-simulator test launch issues recur (entitlement-stripped under `CODE_SIGNING_ALLOWED=NO`), that's the pre-existing infrastructure quirk from commit `ae4c90e`'s log, not a regression from this work.
