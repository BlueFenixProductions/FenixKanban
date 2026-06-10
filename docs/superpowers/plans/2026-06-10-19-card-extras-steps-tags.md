# Issue #19 (Slice 1): Steps Checklist + Tags-as-Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first #19 slice per Captain's rulings — a fizzy-backed, online-only steps checklist in the card detail view, and full multi-tag support by upgrading the local `Label` relationship from to-one to many-to-many (fizzy tags ⇄ Labels, all of them, with chips on card faces and a multi-select editor).

**Architecture:** CoreData model v6 renames `Card.label` (to-one) → `Card.labels` (to-many, lightweight migration via `renamingIdentifier`). The sync engine maps **all** pulled tags to Labels (replacing the Phase 4a first-tag-only limitation); local label toggles on fizzy-paired cards push immediately via `toggleCardTag` (online-only, pull LWW is the reconciler). Steps are **not persisted**: a new `CardStepsViewModel` fetches them via `client.card(number:)` when the detail view opens and does CRUD straight against the API with optimistic UI — same online-only pattern as the #16 comments ruling.

**Tech Stack:** SwiftUI (iOS 26 / macOS 26, Liquid Glass rules apply), CoreData + CloudKit (`NSPersistentCloudKitContainer`), Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), `MockURLProtocol` + `ImmediateClock` for client mocking.

---

## Pre-flight (read first)

- **Branch:** work directly on `develop` (repo practice — see #11–#15 wave commits).
- **Simulator flake:** TWO "iPhone 17" sims exist. Before any `make test`:
  ```bash
  xcrun simctl boot 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB 2>/dev/null; xcrun simctl bootstatus 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB
  ```
  "preflight checks / Busy" errors are never code.
- **CoreData version-bump pitfall:** xcodegen bakes `currentVersion` into the pbxproj. Update `.xccurrentversion` **first**, THEN run `make generate`.
- **Mock failure responses:** use **422**, never 500 — the client retries 5xx 3×, making request counts nondeterministic.
- **Run tests:** `make test` (full suite). macOS build check: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build`.
- **Generated accessors:** entities use `codeGenerationType="category"` — after the model change, Xcode generates `Card.labels: NSSet?`, `addToLabels(_:)`, `removeFromLabels(_:)` at build time. No hand-written `Card+CoreDataProperties`.
- After completing the plan, append a section to `TDD_IMPLEMENTATION_STATUS.md` (standing rule).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 6.xcdatamodel/contents` | Create | v6 model: `Card.labels` many-to-many |
| `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion` | Modify | point at v6 |
| `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift` | Modify | add `Card.sortedLabels` |
| `FenixKanban/Core/Persistence/PersistenceController.swift:69` | Modify | preview seed uses `addToLabels` |
| `FenixKanban/Core/Repositories/CardRepository.swift` | Modify | `labels:` param, `clearLabels`, `toggleLabel` |
| `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift:688-703` | Modify | `applyRemote` maps ALL tags → labels |
| `FenixKanban/Features/Card/CardDetailViewModel.swift` | Modify | `selectedLabels` set, async toggle + fizzy push, owns optional `stepsViewModel` |
| `FenixKanban/Features/Card/CardDetailView.swift` | Modify | labels chips row, steps section, registry-resolved client |
| `FenixKanban/Features/Card/CardView.swift` | Modify | chips row (≤3 + "+N") on card face |
| `FenixKanban/Features/Labels/LabelPickerView.swift` | Modify | multi-select (toggle, no auto-dismiss) |
| `FenixKanban/Features/Card/CardStepsViewModel.swift` | Create | online-only steps state + CRUD |
| `FenixKanban/Features/Card/CardStepsSection.swift` | Create | checklist UI section |
| `FenixKanbanTests/Persistence/CoreDataMigrationV6Tests.swift` | Create | v5→v6 lightweight migration proof |
| `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift` | Modify | selectedLabels / toggle / push tests |
| `FenixKanbanTests/ViewModels/CardStepsViewModelTests.swift` | Create | steps VM tests (fixture-verbatim) |
| `FenixKanbanTests/Repositories/CardRepositoryTests.swift` | Modify | labels param assertions |
| `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift:336` | Modify | label assertion → labels |

Existing client surface used (no client changes needed): `card(number:)`, `createStep`, `updateStep`, `deleteStep`, `toggleCardTag`, DTOs `FizzyStep {id, content, completed}`, `FizzyTaggingPayload`.

---

### Task 1: CoreData v6 — `Card.label` → `Card.labels` many-to-many

The schema change is compile-atomic: the model edit, all mechanical call-site updates, and updated existing tests land in one GREEN commit. The RED commit is the migration test, which compiles and fails at runtime against v5 (it inspects the model by name, no generated accessors).

**Files:**
- Create: `FenixKanbanTests/Persistence/CoreDataMigrationV6Tests.swift`
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 6.xcdatamodel/contents`
- Modify: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`
- Modify: `FenixKanban/Core/Persistence/NSManagedObject+Extensions.swift`
- Modify: `FenixKanban/Core/Persistence/PersistenceController.swift:69`
- Modify: `FenixKanban/Core/Repositories/CardRepository.swift`
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`
- Modify: `FenixKanban/Features/Card/CardView.swift`
- Modify: `FenixKanban/Features/Labels/LabelPickerView.swift`
- Modify: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`, `FenixKanbanTests/Repositories/CardRepositoryTests.swift`, `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`

- [ ] **Step 1: Write the failing migration test**

Create `FenixKanbanTests/Persistence/CoreDataMigrationV6Tests.swift`:

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Proves the v5 → v6 lightweight migration: `Card.label` (to-one) becomes
/// `Card.labels` (many-to-many) via `renamingIdentifier="label"`, and existing
/// to-one data survives as a one-element set.
///
/// Both containers use class-stripped model copies (entities resolved to plain
/// NSManagedObject + KVC) so loading two model versions in one process doesn't
/// trip the "multiple NSEntityDescriptions claim subclass Card" warning.
@Suite("CoreData v5→v6 migration", .serialized)
struct CoreDataMigrationV6Tests {

    private func model(named name: String?) throws -> NSManagedObjectModel {
        let bundle = Bundle(for: PluginRegistry.self)
        let momd = try #require(bundle.url(forResource: "FenixKanban", withExtension: "momd"))
        let url = name.map { momd.appendingPathComponent("\($0).mom") } ?? momd
        let model = try #require(NSManagedObjectModel(contentsOf: url))
        let stripped = model.copy() as! NSManagedObjectModel
        for entity in stripped.entities { entity.managedObjectClassName = "NSManagedObject" }
        return stripped
    }

    @Test("current model exposes Card.labels as a to-many relationship")
    func currentModelHasToManyLabels() throws {
        let current = try model(named: nil)
        let card = try #require(current.entitiesByName["Card"])
        let labels = try #require(card.relationshipsByName["labels"],
                                  "Card has no 'labels' relationship — model still at v5")
        #expect(labels.isToMany)
        #expect(labels.destinationEntity?.name == "Label")
        let label = try #require(current.entitiesByName["Label"])
        #expect(label.relationshipsByName["cards"]?.inverseRelationship?.name == "labels")
    }

    @Test("v5 store with card.label migrates to card.labels containing that label")
    func migratesLabelDataForward() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v6-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        }

        // 1. Seed an on-disk store using the OLD v5 model, pure KVC.
        let v5 = try model(named: "FenixKanban 5")
        let oldContainer = NSPersistentContainer(name: "MigV5", managedObjectModel: v5)
        let oldDesc = NSPersistentStoreDescription(url: storeURL)
        oldDesc.shouldAddStoreAsynchronously = false
        oldContainer.persistentStoreDescriptions = [oldDesc]
        var loadError: Error?
        oldContainer.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)

        let oldCtx = oldContainer.viewContext
        let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: oldCtx)
        label.setValue(UUID(), forKey: "id")
        label.setValue("Urgent", forKey: "name")
        label.setValue("#FF0000", forKey: "colorHex")
        let card = NSEntityDescription.insertNewObject(forEntityName: "Card", into: oldCtx)
        card.setValue(UUID(), forKey: "id")
        card.setValue("Migrating card", forKey: "title")
        card.setValue(label, forKey: "label")
        try oldCtx.save()
        for store in oldContainer.persistentStoreCoordinator.persistentStores {
            try oldContainer.persistentStoreCoordinator.remove(store)
        }

        // 2. Re-open with the CURRENT model; lightweight migration must run.
        let current = try model(named: nil)
        let newContainer = NSPersistentContainer(name: "MigV6", managedObjectModel: current)
        let newDesc = NSPersistentStoreDescription(url: storeURL)
        newDesc.shouldAddStoreAsynchronously = false
        newDesc.shouldMigrateStoreAutomatically = true
        newDesc.shouldInferMappingModelAutomatically = true
        newContainer.persistentStoreDescriptions = [newDesc]
        var migError: Error?
        newContainer.loadPersistentStores { _, error in migError = error }
        try #require(migError == nil, "lightweight migration failed: \(String(describing: migError))")

        // 3. The old to-one label is now a member of the to-many labels set.
        let request = NSFetchRequest<NSManagedObject>(entityName: "Card")
        let migrated = try #require(try newContainer.viewContext.fetch(request).first)
        let labels = try #require(migrated.value(forKey: "labels") as? Set<NSManagedObject>)
        #expect(labels.count == 1)
        #expect(labels.first?.value(forKey: "name") as? String == "Urgent")
    }
}
```

- [ ] **Step 2: Run the migration test, verify it fails for the right reason**

```bash
xcrun simctl boot 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB 2>/dev/null; xcrun simctl bootstatus 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB
make test 2>&1 | grep -A3 "CoreData v5→v6"
```
Expected: BOTH tests FAIL — "Card has no 'labels' relationship — model still at v5", and the migration test fails at the same `labels` requirement (current model == v5, no `FenixKanban 5.mom` subversion distinction issue: the `.mom` for v5 exists since v5 is a model version; if `model(named: "FenixKanban 5")` can't be found, the compiled name is `FenixKanban 5.mom` inside the `.momd` — verify with `ls` in the built app bundle before debugging further).

- [ ] **Step 3: Commit the failing test (RED)**

```bash
git add FenixKanbanTests/Persistence/CoreDataMigrationV6Tests.swift
git commit -m "test(19): v5→v6 migration spec — Card.labels many-to-many (RED)"
```

- [ ] **Step 4: Create the v6 model version**

```bash
cd "FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld"
cp -R "FenixKanban 5.xcdatamodel" "FenixKanban 6.xcdatamodel"
```

In `FenixKanban 6.xcdatamodel/contents`, replace the Card `label` relationship line:

```xml
<relationship name="label" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Label" inverseName="cards" inverseEntity="Label"/>
```
with:
```xml
<relationship name="labels" optional="YES" toMany="YES" deletionRule="Nullify" renamingIdentifier="label" destinationEntity="Label" inverseName="cards" inverseEntity="Label"/>
```
and the Label `cards` relationship line:
```xml
<relationship name="cards" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="Card" inverseName="label" inverseEntity="Card"/>
```
with:
```xml
<relationship name="cards" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="Card" inverseName="labels" inverseEntity="Card"/>
```
(Exact v5 lines may differ slightly in attribute order — match on `name="label"` / `inverseName="label"`. Keep everything else identical.)

- [ ] **Step 5: Point `.xccurrentversion` at v6, THEN regenerate the project**

Edit `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`: change `<string>FenixKanban 5.xcdatamodel</string>` → `<string>FenixKanban 6.xcdatamodel</string>`.

```bash
make generate
```

- [ ] **Step 6: Add `Card.sortedLabels` to `NSManagedObject+Extensions.swift`**

Append a Card extension (file already has Board/Column/Label extensions):

```swift
extension Card {
    /// Labels sorted by name for stable chip ordering in UI.
    var sortedLabels: [Label] {
        let set = labels as? Set<Label> ?? []
        return set.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }
}
```

- [ ] **Step 7: Update `CardRepository` to the labels API**

In `CardRepository.swift`, replace the protocol line
```swift
func updateCard(_ card: Card, title: String?, description: String?, dueDate: Date?, isCompleted: Bool?, label: Label?)
```
with
```swift
func updateCard(_ card: Card, title: String?, description: String?, dueDate: Date?, isCompleted: Bool?, labels: Set<Label>?)
```
and replace `updateCard` / `clearLabel` implementations:

```swift
func updateCard(_ card: Card, title: String? = nil, description: String? = nil, dueDate: Date? = nil, isCompleted: Bool? = nil, labels: Set<Label>? = nil) {
    if let title = title { card.title = title }
    if let description = description { card.cardDescription = description }
    if let dueDate = dueDate { card.dueDate = dueDate }
    if let isCompleted = isCompleted { card.isCompleted = isCompleted }
    // nil = leave labels unchanged (use clearLabels to remove all)
    if let labels = labels { card.labels = labels as NSSet }
    card.modifiedAt = Date()
    save()
}

func clearLabels(for card: Card) {
    card.labels = NSSet()
    card.modifiedAt = Date()
    save()
}

func toggleLabel(_ label: Label, on card: Card) {
    if let current = card.labels as? Set<Label>, current.contains(label) {
        card.removeFromLabels(label)
    } else {
        card.addToLabels(label)
    }
    card.modifiedAt = Date()
    save()
}
```
(Note the semantic change from v5: `labels: nil` now means *unchanged*, where `label: nil` used to clear. The only caller that relied on clearing-by-nil is `CardDetailViewModel.save`, updated below to always pass the set.)

- [ ] **Step 8: Fix the preview seed in `PersistenceController.swift`**

Line 69: `card.label = label` → `card.addToLabels(label)`.

- [ ] **Step 9: Minimal compile fix in `FizzySyncEngine.applyRemote` (behavior unchanged: first tag only)**

Replace (around line 698):
```swift
        if let firstTag = remote.tags.first {
            card.label = findOrCreateLabel(name: firstTag)
        } else {
            card.label = nil
        }
```
with:
```swift
        // Still first-tag-only here; Task 2 widens this to ALL tags (RED first).
        if let firstTag = remote.tags.first {
            card.labels = NSSet(object: findOrCreateLabel(name: firstTag))
        } else {
            card.labels = NSSet()
        }
```

- [ ] **Step 10: Update `CardDetailViewModel` to `selectedLabels`**

Replace the full file body (push-to-fizzy lands in Task 3; this step is local-only):

```swift
import CoreData
import SwiftUI

final class CardDetailViewModel: ObservableObject {
    @Published var card: Card
    @Published var title: String
    @Published var cardDescription: String
    @Published var dueDate: Date?
    @Published var isCompleted: Bool
    @Published var selectedLabels: Set<Label>
    @Published var showLabelPicker = false
    @Published var showDatePicker = false

    private let cardRepository: CardRepository
    private let labelRepository: LabelRepository

    var availableColumns: [Column] {
        card.column?.board?.sortedColumns ?? []
    }

    var sortedSelectedLabels: [Label] {
        selectedLabels.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    init(card: Card, context: NSManagedObjectContext) {
        self.card = card
        self.title = card.title ?? ""
        self.cardDescription = card.cardDescription ?? ""
        self.dueDate = card.dueDate
        self.isCompleted = card.isCompleted
        self.selectedLabels = card.labels as? Set<Label> ?? []
        self.cardRepository = CardRepository(context: context)
        self.labelRepository = LabelRepository(context: context)
    }

    func save() {
        cardRepository.updateCard(
            card,
            title: title.isEmpty ? nil : title,
            description: cardDescription.isEmpty ? nil : cardDescription,
            dueDate: dueDate,
            isCompleted: isCompleted,
            labels: selectedLabels
        )
    }

    func moveToColumn(_ column: Column) {
        let currentIndex = column.sortedCards.count
        cardRepository.moveCard(card, to: column, at: currentIndex)
    }

    func clearDueDate() {
        dueDate = nil
        cardRepository.clearDueDate(for: card)
    }

    func clearLabels() {
        selectedLabels = []
        cardRepository.clearLabels(for: card)
    }

    func toggleLabel(_ label: Label) {
        if selectedLabels.contains(label) {
            selectedLabels.remove(label)
        } else {
            selectedLabels.insert(label)
        }
        save()
    }

    func toggleGolden() {
        card.isGolden.toggle()
        card.modifiedAt = Date()
        card.column?.modifiedAt = Date()
        card.column?.board?.modifiedAt = Date()
        try? card.managedObjectContext?.save()
        objectWillChange.send()
    }
}
```

- [ ] **Step 11: Make `LabelPickerView` multi-select**

Replace the file body:

```swift
import SwiftUI
import CoreData

struct LabelPickerView: View {
    let selectedLabels: Set<Label>
    let onToggle: (Label) -> Void
    @StateObject private var viewModel: LabelManagementViewModel
    @Environment(\.dismiss) private var dismiss

    init(selectedLabels: Set<Label>, context: NSManagedObjectContext, onToggle: @escaping (Label) -> Void) {
        self.selectedLabels = selectedLabels
        self.onToggle = onToggle
        _viewModel = StateObject(wrappedValue: LabelManagementViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.labels, id: \.objectID) { label in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: label.colorHex ?? "#808080"))
                            .frame(width: 20, height: 20)

                        Text(label.name ?? "Untitled")

                        Spacer()

                        if selectedLabels.contains(label) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle(label) }
                    .accessibilityAddTraits(selectedLabels.contains(label) ? .isSelected : [])
                }
            }
            .listStyle(.plain)
            .navigationTitle("Labels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
```
(Toggling no longer dismisses — the sheet re-renders live because `CardDetailView` observes the view model and rebuilds the sheet content with the new set. "Cancel" becomes "Done": toggles apply immediately, there is nothing to cancel.)

- [ ] **Step 12: Update `CardDetailView` label row + sheet wiring**

Replace the `// Label` HStack (lines 54–74) with:

```swift
                    // Labels (multi)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Labels")
                        Spacer()
                        if viewModel.selectedLabels.isEmpty {
                            Button("Select") { viewModel.showLabelPicker = true }
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                ForEach(viewModel.sortedSelectedLabels, id: \.objectID) { label in
                                    if let name = label.name, let hex = label.colorHex {
                                        LabelBadge(name: name, colorHex: hex)
                                    }
                                }
                            }
                            .onTapGesture { viewModel.showLabelPicker = true }
                            Button {
                                viewModel.clearLabels()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.crossPlatformCaption)
                            }
                            .accessibilityLabel("Remove all labels")
                        }
                    }
```

and the label sheet (lines 135–140) with:

```swift
            .sheet(isPresented: $viewModel.showLabelPicker) {
                LabelPickerView(
                    selectedLabels: viewModel.selectedLabels,
                    context: viewModel.card.managedObjectContext!
                ) { label in
                    viewModel.toggleLabel(label)
                }
            }
```

- [ ] **Step 13: Update `CardView` to a chips row**

Remove the single-badge block from the title HStack (lines 48–52) and add a chips row between the title HStack and the due-date block:

```swift
            if !card.sortedLabels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(card.sortedLabels.prefix(3)), id: \.objectID) { label in
                        if let name = label.name, let hex = label.colorHex {
                            LabelBadge(name: name, colorHex: hex)
                        }
                    }
                    if card.sortedLabels.count > 3 {
                        Text("+\(card.sortedLabels.count - 3)")
                            .font(.crossPlatformCaption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
```

- [ ] **Step 14: Update the three existing test files**

`FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`:
- `initialValues`: `#expect(viewModel.selectedLabel == nil)` → `#expect(viewModel.selectedLabels.isEmpty)`
- `selectLabel` test → toggle semantics:
```swift
    @Test func toggleLabelAddsAndRemoves() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")

        viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels == [label])
        #expect((card.labels as? Set<Label>) == [label])

        viewModel.toggleLabel(label)
        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
    }

    @Test func multipleLabelsCoexist() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let bug = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        let urgent = labelRepo.createLabel(name: "Urgent", colorHex: "#00FF00")

        viewModel.toggleLabel(bug)
        viewModel.toggleLabel(urgent)
        #expect(viewModel.selectedLabels == [bug, urgent])
        #expect(viewModel.sortedSelectedLabels.map(\.name) == ["Bug", "Urgent"])
    }
```
- `clearLabel` test → `clearLabels`:
```swift
    @Test func clearLabels() {
        let labelRepo = LabelRepository(context: persistence.viewContext)
        let label = labelRepo.createLabel(name: "Bug", colorHex: "#FF0000")
        viewModel.toggleLabel(label)

        viewModel.clearLabels()
        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
    }
```

`FenixKanbanTests/Repositories/CardRepositoryTests.swift` (lines 51, 57):
```swift
        cardRepo.updateCard(card, title: "Updated", description: "A description", dueDate: Date(), isCompleted: true, labels: [label])
        // ...
        #expect((card.labels as? Set<Label>) == [label])
```

`FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` line 336:
```swift
        #expect(golden?.sortedLabels.first?.name == "bug")
```

- [ ] **Step 15: Build both platforms, run full suite**

```bash
make build
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build
make test
```
Expected: builds clean, no new warnings, ALL tests pass including both migration tests.

- [ ] **Step 16: Commit (GREEN)**

```bash
git add -A
git commit -m "feat(19): CoreData v6 — Card.labels many-to-many, multi-label UI plumbing (GREEN)"
```

**Fallback if the lightweight migration test fails** (rename + cardinality change combined is the one risky bit). Simplest reliable path: in v6 keep the relationship named `label` but set `toMany="YES"` (pure cardinality change, no rename — explicitly supported by lightweight migration, data survives), then expose `var labels: Set<Label>` / `addToLabels` / `removeFromLabels` as computed wrappers over `label` in `NSManagedObject+Extensions.swift` so every other task's code compiles unchanged. (Do NOT drop the old relationship and backfill in code — once lightweight migration drops `label`, the data is gone.) A custom `NSMappingModel` is the heavier alternative; only reach for it if the wrapper approach proves untenable. Decide based on the actual error; do not ship without the data-survival test passing.

---

### Task 2: Sync engine maps ALL tags ⇄ labels

**Files:**
- Modify: `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`
- Modify: `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`

- [ ] **Step 1: Write the failing tests**

Add to the steady-state pull suite in `FizzySyncEngineTests.swift` (the suite around line 264 with the `Harness`; reuse its harness + handler conventions — inline card JSON matches the existing shape at line 315):

```swift
    @Test("pull: card with three tags maps all three to labels")
    func pullMapsAllTags() async throws {
        let h = Harness()
        defer { h.tearDown() }

        let cardsJSON = """
        [{"id":"fzT1","number":11,"title":"Tagged","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":["bug","urgent","backend"],"golden":false,"last_active_at":"2026-06-10T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/11"}]
        """
        // Wire the harness handler exactly like the existing pull tests:
        // GET columns → existing columns JSON, GET cards → cardsJSON.
        // (Copy the handler block from the neighboring pull test verbatim,
        // substituting cardsJSON.)

        _ = try await h.engine.sync()

        let card = h.cardRepo.fetchAllCards(in: h.board).first { $0.fizzyNumber == 11 }
        let names = card?.sortedLabels.compactMap(\.name)
        #expect(names == ["backend", "bug", "urgent"])
    }

    @Test("pull: tags removed remotely clears local labels")
    func pullClearsRemovedTags() async throws {
        let h = Harness()
        defer { h.tearDown() }

        // Seed a paired local card that already has two labels.
        let card = h.cardRepo.createCard(in: h.column, title: "Was tagged")
        card.fizzyID = "fzT2"
        card.fizzyNumber = 12
        let repo = LabelRepository(context: h.persistence.viewContext)
        card.addToLabels(repo.createLabel(name: "bug", colorHex: "#FF0000"))
        card.addToLabels(repo.createLabel(name: "urgent", colorHex: "#00FF00"))
        try h.persistence.viewContext.save()

        let cardsJSON = """
        [{"id":"fzT2","number":12,"title":"Was tagged","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-06-11T00:00:00Z","created_at":"2026-06-10T00:00:00Z","url":"https://fizzy.bluefenix.net/ACCT/cards/12"}]
        """
        // Same handler wiring as above.

        _ = try await h.engine.sync()
        #expect(card.sortedLabels.isEmpty)
    }
```

(Exact harness/handler plumbing: mirror the nearest existing steady-state pull test in the same file — same suite init, same `MockURLProtocol.handler` route-by-path block, same ETag/pagination headers if it sets them. The two tests above only vary the cards payload and assertions.)

- [ ] **Step 2: Run, verify both fail**

```bash
make test 2>&1 | grep -B1 -A4 "maps all three\|clears removed"
```
Expected: `pullMapsAllTags` FAILS — names == ["bug"] (first-tag-only). `pullClearsRemovedTags` PASSES or FAILS depending on remote-newer LWW path — if it passes already, keep it as a regression guard.

- [ ] **Step 3: Commit (RED)**

```bash
git add FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift
git commit -m "test(19): sync pull maps ALL fizzy tags to labels (RED)"
```

- [ ] **Step 4: Implement in `applyRemote`**

Replace the Task 1 Step 9 block with:

```swift
        // All remote tags map to local Labels (issue #19 lifts the Phase 4a
        // first-tag-only limitation). Remote is authoritative on pull (LWW).
        let remoteLabels = remote.tags.map { findOrCreateLabel(name: $0) }
        card.labels = NSSet(array: remoteLabels)
```

Also update the stale doc comment above `applyRemote` (lines 682–683): replace the "maps only the first remote tag" sentence with "Maps every remote tag to a local `Label` (find-or-create by case-insensitive name)."

- [ ] **Step 5: Run full suite, verify green**

```bash
make test
```
Expected: PASS, including the Task 1 migration tests and the engine suite.

- [ ] **Step 6: Commit (GREEN)**

```bash
git add FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift
git commit -m "feat(19): sync pull maps all fizzy tags to labels (GREEN)"
```

---

### Task 3: Tag toggles push to Fizzy from the detail view (online-only)

**Files:**
- Modify: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`

- [ ] **Step 1: Write the failing tests**

Add a new suite to `CardDetailViewModelTests.swift` (the file already imports what's needed; this suite needs `MockURLProtocol` from `FenixKanbanTests/Services/Fizzy/MockURLProtocol.swift` — same target, no import needed):

```swift
@Suite("CardDetail ViewModel — fizzy tag push", .serialized)
@MainActor
struct CardDetailViewModelTagPushTests {
    let persistence: PersistenceController
    let card: Card
    let label: Label
    let viewModel: CardDetailViewModel

    init() {
        MockURLProtocol.reset()
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let cardRepo = CardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "Board")
        let column = boardRepo.createColumn(in: board, name: "Col")
        card = cardRepo.createCard(in: column, title: "Paired Card")
        card.fizzyID = "fz7"
        card.fizzyNumber = 7
        label = LabelRepository(context: persistence.viewContext).createLabel(name: "bug", colorHex: "#FF0000")
        try! persistence.viewContext.save()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
        viewModel = CardDetailViewModel(card: card, context: persistence.viewContext, fizzyClient: client)
    }

    @Test("toggle on a paired card POSTs the tagging toggle")
    func toggleOnPairedCardPosts() async throws {
        MockURLProtocol.handler = { request in
            (Data(), MockURLProtocol.response(for: request, status: 204))
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels == [label])
        let post = MockURLProtocol.requests.first { $0.httpMethod == "POST" }
        let url = try #require(post?.url)
        #expect(url.path.hasSuffix("/cards/7/taggings"))
        MockURLProtocol.reset()
    }

    @Test("422 from taggings reverts the toggle and surfaces an error")
    func failedPushReverts() async throws {
        MockURLProtocol.handler = { request in
            (Data("{\"error\":\"nope\"}".utf8), MockURLProtocol.response(for: request, status: 422))
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels.isEmpty)
        #expect((card.labels as? Set<Label>)?.isEmpty == true)
        #expect(viewModel.errorMessage != nil)
        MockURLProtocol.reset()
    }

    @Test("unpaired card toggles locally without any network call")
    func unpairedCardStaysLocal() async throws {
        card.fizzyNumber = 0
        card.fizzyID = nil
        MockURLProtocol.handler = { _ in
            Issue.record("no network call expected for unpaired card")
            throw URLError(.unsupportedURL)
        }

        await viewModel.toggleLabel(label)

        #expect(viewModel.selectedLabels == [label])
        #expect(MockURLProtocol.requests.isEmpty)
        MockURLProtocol.reset()
    }
}
```

NOTE: `toggleLabel` becomes `async`. Update the three Task 1 toggle tests in the existing suite to `await viewModel.toggleLabel(...)` inside `async` test funcs (no client passed there → no network, no mock needed).

- [ ] **Step 2: Run, verify failure is a compile error on the new init param + async**

Expected: does not compile — `CardDetailViewModel` has no `fizzyClient:` parameter and `toggleLabel` isn't async. That is the right reason; proceed (no RED commit for a non-compiling state — fold test+impl into one commit this task, noting the bend in the commit body).

- [ ] **Step 3: Implement push in `CardDetailViewModel`**

Changes to the Task 1 version:

```swift
    @Published var errorMessage: String?

    private let fizzyClient: FizzyClient?

    init(card: Card, context: NSManagedObjectContext, fizzyClient: FizzyClient? = nil) {
        // ... existing assignments ...
        self.fizzyClient = fizzyClient
    }

    /// Toggles a label locally, then mirrors the change to Fizzy when the
    /// card is paired (`fizzyNumber > 0`) and a client is available.
    /// Online-only by Captain's ruling on #19: a failed push reverts the
    /// local toggle and surfaces an error — the next sync pull is the
    /// reconciler of last resort.
    func toggleLabel(_ label: Label) async {
        let wasSelected = selectedLabels.contains(label)
        if wasSelected { selectedLabels.remove(label) } else { selectedLabels.insert(label) }
        save()

        guard card.fizzyNumber > 0, let client = fizzyClient, let tagTitle = label.name else { return }
        do {
            try await client.toggleCardTag(number: Int(card.fizzyNumber), tagTitle: tagTitle)
        } catch {
            if wasSelected { selectedLabels.insert(label) } else { selectedLabels.remove(label) }
            save()
            errorMessage = "Couldn't update tag “\(tagTitle)” on Fizzy."
        }
    }
```

`CardDetailViewModel` must be `@MainActor` for the async mutation ordering to be deterministic — add `@MainActor` to the class declaration (the existing test suite is already `@MainActor`; views construct it on the main actor).

- [ ] **Step 4: Wire the client in `CardDetailView` and update the picker callback**

In `CardDetailView.init`:

```swift
    init(card: Card, context: NSManagedObjectContext) {
        let provider = PluginRegistry.shared.provider(named: "Fizzy") as? FizzySyncProvider
        _viewModel = StateObject(wrappedValue: CardDetailViewModel(
            card: card,
            context: context,
            fizzyClient: provider?.makeClient()
        ))
    }
```
(`PluginRegistry` and `FizzySyncProvider` are both `@MainActor`; SwiftUI view inits run on the main actor — no isolation gymnastics needed. The two existing call sites pass `(card:context:)` and are unaffected.)

Picker callback in the sheet becomes:
```swift
                ) { label in
                    Task { await viewModel.toggleLabel(label) }
                }
```

Add an error alert after the existing `.onChange`:
```swift
            .alert("Sync Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
```

- [ ] **Step 5: Run full suite + both builds**

```bash
make test
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build
```
Expected: all pass, no warnings.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(19): paired-card label toggles push toggleCardTag, revert on failure

Test+impl in one commit: the RED state was a compile error (new init param)."
```

---

### Task 4: `CardStepsViewModel` — online-only steps CRUD

**Files:**
- Create: `FenixKanbanTests/ViewModels/CardStepsViewModelTests.swift`
- Create: `FenixKanban/Features/Card/CardStepsViewModel.swift`

- [ ] **Step 1: Write the failing tests**

Create `FenixKanbanTests/ViewModels/CardStepsViewModelTests.swift`. The load test consumes `card_detail_doc.json` **verbatim** (wire-shape fixture rule); the create flow consumes `step_doc.json`.

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("CardSteps ViewModel", .serialized)
@MainActor
struct CardStepsViewModelTests {

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
    }

    // Same fixture-resolution strategy as FizzyClientTests.loadFixture.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: MockURLProtocol.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let testURL = URL(fileURLWithPath: #file)
        let fixturePath = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    @Test("load fetches the card detail and exposes its steps (fixture verbatim)")
    func loadExposesSteps() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        MockURLProtocol.handler = { request in
            (detail, MockURLProtocol.ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()

        #expect(vm.steps.count == 2)
        #expect(vm.steps[0].content == "This is the first step")
        #expect(vm.steps[0].completed == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.progressText == "Steps (0/2)")
    }

    @Test("addStep POSTs, follows Location, appends the created step")
    func addStepAppends() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let stepData = try loadFixture("step_doc")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST", request.url!.path.hasSuffix("/cards/1/steps") {
                return (Data(), MockURLProtocol.response(
                    for: request, status: 201,
                    headers: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1/steps/03f5v9zo9qlcwwpyc0ascnikz"]
                ))
            }
            if request.httpMethod == "GET", request.url!.path.hasSuffix("/steps/03f5v9zo9qlcwwpyc0ascnikz") {
                return (stepData, MockURLProtocol.ok(for: request))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.addStep(content: "Write tests")

        #expect(vm.steps.map(\.content) == ["Write tests"])
        #expect(vm.errorMessage == nil)
    }

    @Test("addStep ignores whitespace-only content without a network call")
    func addStepIgnoresEmpty() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { _ in throw URLError(.unsupportedURL) }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.addStep(content: "   ")

        #expect(vm.steps.isEmpty)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("toggleStep flips optimistically and PUTs the new completed state")
    func toggleStepPuts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        let updated = Data("""
        {"id":"03f8huu0sog76g3s975963b5e","content":"This is the first step","completed":true}
        """.utf8)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                return (updated, MockURLProtocol.ok(for: request))
            }
            return (detail, MockURLProtocol.ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()
        await vm.toggleStep(vm.steps[0])

        #expect(vm.steps[0].completed == true)
        #expect(vm.progressText == "Steps (1/2)")
        let put = MockURLProtocol.requests.first { $0.httpMethod == "PUT" }
        #expect(put?.url?.path.hasSuffix("/cards/1/steps/03f8huu0sog76g3s975963b5e") == true)
    }

    @Test("toggleStep reverts on 422 and surfaces an error")
    func toggleStepReverts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                return (Data("{\"error\":\"nope\"}".utf8), MockURLProtocol.response(for: request, status: 422))
            }
            return (detail, MockURLProtocol.ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()
        await vm.toggleStep(vm.steps[0])

        #expect(vm.steps[0].completed == false)
        #expect(vm.errorMessage != nil)
    }

    @Test("deleteStep removes optimistically; 422 restores at original index")
    func deleteStepReverts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        var failDelete = true
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                if failDelete {
                    return (Data("{\"error\":\"nope\"}".utf8), MockURLProtocol.response(for: request, status: 422))
                }
                return (Data(), MockURLProtocol.response(for: request, status: 204))
            }
            return (detail, MockURLProtocol.ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()

        // Failed delete restores the step at index 0.
        await vm.deleteStep(vm.steps[0])
        #expect(vm.steps.count == 2)
        #expect(vm.steps[0].content == "This is the first step")
        #expect(vm.errorMessage != nil)

        // Successful delete removes it.
        failDelete = false
        vm.errorMessage = nil
        await vm.deleteStep(vm.steps[0])
        #expect(vm.steps.map(\.content) == ["This is the second step"])
        #expect(vm.errorMessage == nil)
    }
}
```

- [ ] **Step 2: Verify RED**

Does not compile (`CardStepsViewModel` doesn't exist) — right reason. Test+impl share one commit, noted in the body.

- [ ] **Step 3: Implement `CardStepsViewModel`**

Create `FenixKanban/Features/Card/CardStepsViewModel.swift`:

```swift
import Foundation

/// Online-only steps (checklist) state for a fizzy-paired card.
///
/// Captain's ruling on #19: steps are NOT persisted locally — they're fetched
/// from the single-card endpoint when the detail view opens, and every
/// mutation goes straight to the API with optimistic UI + revert-on-failure.
/// The next pull is never involved (board pulls don't carry steps).
@MainActor
final class CardStepsViewModel: ObservableObject {
    @Published private(set) var steps: [FizzyStep] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let cardNumber: Int
    private let client: FizzyClient

    init(cardNumber: Int, client: FizzyClient) {
        self.cardNumber = cardNumber
        self.client = client
    }

    var progressText: String {
        "Steps (\(steps.filter(\.completed).count)/\(steps.count))"
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            steps = try await client.card(number: cardNumber).steps ?? []
        } catch {
            errorMessage = "Couldn't load steps."
        }
    }

    func addStep(content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let created = try await client.createStep(cardNumber: cardNumber, content: trimmed)
            steps.append(created)
        } catch {
            errorMessage = "Couldn't add the step."
        }
    }

    func toggleStep(_ step: FizzyStep) async {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        let flipped = FizzyStep(id: step.id, content: step.content, completed: !step.completed)
        steps[index] = flipped  // optimistic
        do {
            let updated = try await client.updateStep(cardNumber: cardNumber, id: step.id, completed: flipped.completed)
            if let i = steps.firstIndex(where: { $0.id == step.id }) {
                steps[i] = updated
            }
        } catch {
            if let i = steps.firstIndex(where: { $0.id == step.id }) {
                steps[i] = step  // revert
            }
            errorMessage = "Couldn't update the step."
        }
    }

    func deleteStep(_ step: FizzyStep) async {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps.remove(at: index)  // optimistic
        do {
            try await client.deleteStep(cardNumber: cardNumber, id: step.id)
        } catch {
            steps.insert(step, at: min(index, steps.count))  // revert
            errorMessage = "Couldn't delete the step."
        }
    }

    func deleteSteps(at offsets: IndexSet) async {
        for step in offsets.compactMap({ steps.indices.contains($0) ? steps[$0] : nil }) {
            await deleteStep(step)
        }
    }
}
```

- [ ] **Step 4: Run the new suite + full tests**

```bash
make test 2>&1 | grep -A2 "CardSteps"
make test
```
Expected: all 6 new tests PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Card/CardStepsViewModel.swift FenixKanbanTests/ViewModels/CardStepsViewModelTests.swift
git commit -m "feat(19): CardStepsViewModel — online-only steps CRUD, optimistic w/ revert

Test+impl in one commit: RED state was a compile error (new type)."
```

---

### Task 5: Steps UI section in the card detail view

**Files:**
- Create: `FenixKanban/Features/Card/CardStepsSection.swift`
- Modify: `FenixKanban/Features/Card/CardDetailViewModel.swift`
- Modify: `FenixKanban/Features/Card/CardDetailView.swift`
- Modify: `FenixKanbanTests/ViewModels/CardDetailViewModelTests.swift`

- [ ] **Step 1: Write the failing tests (steps VM exposure)**

Add to the tag-push suite from Task 3 (it already builds a paired card + client):

```swift
    @Test("paired card with a client exposes a steps view model")
    func pairedCardExposesStepsVM() {
        #expect(viewModel.stepsViewModel != nil)
    }
```

And in the original (unpaired, no-client) suite:

```swift
    @Test func unpairedCardHasNoStepsVM() {
        #expect(viewModel.stepsViewModel == nil)
    }
```

- [ ] **Step 2: Verify RED**

Compile error: `stepsViewModel` doesn't exist. Right reason.

- [ ] **Step 3: Expose `stepsViewModel` from `CardDetailViewModel`**

Add to the class:

```swift
    /// Present only for fizzy-paired cards with a live client — drives the
    /// steps checklist section (issue #19, online-only).
    let stepsViewModel: CardStepsViewModel?
```
and in `init`, after `self.fizzyClient = fizzyClient`:
```swift
        if card.fizzyNumber > 0, let client = fizzyClient {
            self.stepsViewModel = CardStepsViewModel(cardNumber: Int(card.fizzyNumber), client: client)
        } else {
            self.stepsViewModel = nil
        }
```

- [ ] **Step 4: Create `CardStepsSection.swift`**

```swift
import SwiftUI

/// Checklist section for a fizzy-paired card's detail Form (issue #19).
/// Online-only: rendered only when the parent view model exposes a
/// `CardStepsViewModel`.
struct CardStepsSection: View {
    @ObservedObject var viewModel: CardStepsViewModel
    @State private var newStepText = ""

    var body: some View {
        Section {
            ForEach(viewModel.steps, id: \.id) { step in
                Button {
                    Task { await viewModel.toggleStep(step) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: step.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.completed ? Color.accentColor : Color.secondary)
                        Text(step.content)
                            .strikethrough(step.completed)
                            .foregroundStyle(step.completed ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.content)
                .accessibilityValue(step.completed ? "Completed" : "Not completed")
                .accessibilityHint("Toggles completion on Fizzy.")
            }
            .onDelete { offsets in
                Task { await viewModel.deleteSteps(at: offsets) }
            }

            TextField("Add a step", text: $newStepText)
                .onSubmit {
                    let content = newStepText
                    newStepText = ""
                    Task { await viewModel.addStep(content: content) }
                }
                .accessibilityIdentifier("steps-add-field")
        } header: {
            HStack {
                Text(viewModel.progressText)
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task { await viewModel.load() }
    }
}
```

(No `.background` anywhere — Form rows keep their system Liquid Glass surfaces.)

- [ ] **Step 5: Render the section in `CardDetailView`**

After the second `Section { ... }` (the one ending with the Completed toggle), add:

```swift
                if let stepsVM = viewModel.stepsViewModel {
                    CardStepsSection(viewModel: stepsVM)
                }
```

- [ ] **Step 6: Run tests + both platform builds**

```bash
make test
make build
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build
```
Expected: green, clean, no warnings. `.onDelete` is iOS-swipe + macOS-Edit-menu compatible inside Form — verify the macOS build emits no platform warnings.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(19): steps checklist section in card detail (paired cards, GREEN)"
```

---

### Task 6: Finalize — status doc, full verification

- [ ] **Step 1: Full verification pass**

```bash
xcrun simctl boot 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB 2>/dev/null; xcrun simctl bootstatus 1CCA4B1C-2345-4642-A29C-237D8BE5B9EB
make test
make build
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' build
```
Expected: every suite green (baseline was 326 tests / 68 suites; this plan adds ~15), both builds clean, zero new warnings.

- [ ] **Step 2: Append §19 to `TDD_IMPLEMENTATION_STATUS.md`**

Follow the §17/§18 format: date, issue #19, commits, what shipped (CoreData v6 labels many-to-many + migration test, all-tags sync mapping, paired tag push w/ revert, CardStepsViewModel + section), verification counts, and known gray areas (label color for server-created tags is FNV-derived; `clearLabels` on a paired card does NOT push per-tag toggles — next pull reconciles; steps are invisible for unpaired cards by design).

- [ ] **Step 3: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "docs: log #19 slice 1 (steps + tags) in TDD status"
```

- [ ] **Step 4: Report back to the Captain**

Summarize: what shipped, test delta, any deviations from this plan (especially if the migration fallback was needed), and propose the #19 close-out comment for GitHub (posting needs explicit approval each session).

---

## Known risks & decisions encoded above

1. **Lightweight migration (rename + to-one→to-many in one step)** — proven by `CoreDataMigrationV6Tests` before anything else lands. Fallback documented in Task 1.
2. **CloudKit**: many-to-many with inverse is supported by `NSPersistentCloudKitContainer`; both sides `Nullify`, both optional. The migration test runs without CloudKit (plain `NSPersistentContainer`), matching the `useCloudKit: false` test convention.
3. **`clearLabels` on a paired card** is local-only (no N toggle calls) — divergence is reconciled by the next pull (remote-authoritative on tags). Logged as a gray area, not silent.
4. **Steps for unpaired cards don't exist** — Captain's ruling (online-only, fizzy-backed). The section simply isn't rendered.
5. **Two test+impl single commits** (Tasks 3–5) where RED is a compile error — noted in commit bodies per repo TDD convention.
