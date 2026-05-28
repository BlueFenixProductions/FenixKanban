# Fizzy Integration — Phase 3: CoreData Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three optional attributes to the `Card` Core Data entity — `fizzyID`, `fizzyEtag`, `fizzyUpdatedAt` — via a lightweight migration to a new `FenixKanban 3.xcdatamodel`. Phase 4's sync engine consumes these; nothing else changes.

**Architecture:** Same pattern as the recently shipped `isGolden` migration (v1 → v2 → v3 chain). The model is `codeGenerationType="category"`, so adding optional fields produces `var fizzyID: String?` etc. on `Card` automatically with no Swift code to write. Lightweight migration is inferred by Core Data when the schema diff is additive + optional. CloudKit stays happy because the attributes are optional (CloudKit's hard requirement).

**Tech Stack:** Core Data lightweight migration, `NSPersistentCloudKitContainer`, Swift Testing, `usedWithCloudKit="YES"` model flag.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md` (§ Data model → CoreData)

**Out of scope for Phase 3** (deferred):
- The sync engine that reads/writes these fields — Phase 4
- The "first-sync mode" behaviors (push local / replace local / merge) — Phase 4 (engine) + Phase 5 (UI selector)
- Any UI surfacing of `fizzyID` / `fizzyEtag` / `fizzyUpdatedAt` to the user — none planned for MVP

---

## File Structure

**New files:**
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/contents` — full model XML, copy of v2 + three new `Card` attributes
- `FenixKanbanTests/Models/CardFizzyAttributesTests.swift` — defaults + round-trip tests (~50 LOC)

**Modified:**
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion` — bump from `FenixKanban 2.xcdatamodel` to `FenixKanban 3.xcdatamodel`
- `TDD_IMPLEMENTATION_STATUS.md` — append Phase 3 entry

**Not modified:**
- v1 and v2 model contents files — kept verbatim so migration chain stays intact for users upgrading from older builds.
- `PersistenceController.swift` — no code change. Lightweight migration is automatic when `NSPersistentCloudKitContainer` is configured with `shouldInferMappingModelAutomatically` (the default).
- Any Swift code using `Card` — `codeGenerationType="category"` synthesizes the new accessors automatically.

---

## Task 1: Create v3 model + bump current version (red → green)

**Files:**
- Create: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/contents`
- Modify: `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion`
- Create: `FenixKanbanTests/Models/CardFizzyAttributesTests.swift`

The red phase writes tests against properties that don't exist yet (`card.fizzyID`, etc.) — they fail because Core Data's category-codegen hasn't synthesized the accessors. The green phase adds the v3 model and bumps the current-version pointer; codegen produces the accessors; tests pass.

- [ ] **Step 1: Write the failing test**

Content (write to `FenixKanbanTests/Models/CardFizzyAttributesTests.swift`):

```swift
import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("Card Fizzy sync attributes", .serialized)
@MainActor
struct CardFizzyAttributesTests {
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

    @Test("fizzyID, fizzyEtag, fizzyUpdatedAt all default to nil on insert")
    func defaultsAreNil() {
        #expect(card.fizzyID == nil)
        #expect(card.fizzyEtag == nil)
        #expect(card.fizzyUpdatedAt == nil)
    }

    @Test("fizzyID round-trips through save/refresh")
    func fizzyIDPersists() throws {
        card.fizzyID = "03f5vaeq985jlvwv3arl4srq2"
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyID == "03f5vaeq985jlvwv3arl4srq2")
    }

    @Test("fizzyEtag round-trips through save/refresh")
    func fizzyEtagPersists() throws {
        card.fizzyEtag = "\"abc123\""
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        #expect(card.fizzyEtag == "\"abc123\"")
    }

    @Test("fizzyUpdatedAt round-trips through save/refresh")
    func fizzyUpdatedAtPersists() throws {
        let date = Date(timeIntervalSince1970: 1_734_567_890)
        card.fizzyUpdatedAt = date
        try persistence.viewContext.save()
        persistence.viewContext.refresh(card, mergeChanges: false)
        let read = try #require(card.fizzyUpdatedAt)
        #expect(abs(read.timeIntervalSince(date)) < 0.001)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/CardFizzyAttributesTests \
  test 2>&1 | tail -20
```

Expected: build fails — `Value of type 'Card' has no member 'fizzyID'` (or similar) for each of the three properties. This is the red phase.

- [ ] **Step 3: Create the v3 model file**

Create the directory `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/` (note the space in the directory name — Core Data versioned bundles use this convention).

Then create `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/contents` with this exact content (a clone of v2 plus three new `Card` attributes, alphabetically slotted):

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
        <attribute name="fizzyEtag" optional="YES" attributeType="String"/>
        <attribute name="fizzyID" optional="YES" attributeType="String"/>
        <attribute name="fizzyUpdatedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
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

The three new lines on the `Card` entity (and only those) are:

```xml
        <attribute name="fizzyEtag" optional="YES" attributeType="String"/>
        <attribute name="fizzyID" optional="YES" attributeType="String"/>
        <attribute name="fizzyUpdatedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
```

All three are `optional="YES"` (CloudKit requirement). `usedWithCloudKit="YES"` is preserved on the root `<model>` element.

- [ ] **Step 4: Bump the current-version pointer**

Replace the content of `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>_XCCurrentVersionName</key>
	<string>FenixKanban 3.xcdatamodel</string>
</dict>
</plist>
```

(Single character change vs. v2: `2` → `3` in the `<string>` value.)

- [ ] **Step 5: Regenerate Xcode project + run tests**

```bash
make generate
git checkout HEAD -- FenixKanban.xcodeproj/xcshareddata/xcschemes/FenixKanban.xcscheme
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/CardFizzyAttributesTests \
  test 2>&1 | tail -15
```

Expected: 4 tests pass. If the simulator returns "Busy", `xcrun simctl shutdown all && sleep 3` then retry.

- [ ] **Step 6: Run the FULL test suite to confirm no migration regressions**

The lightweight migration from v2 → v3 should be inferred automatically. Existing tests using `Card` should keep passing because the new attributes are optional and additive.

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with ~173 tests in ~38 suites passed` (Phase 2's 169 + Phase 3's 4 = 173). If anything regresses, the most likely culprit is the v3 XML being malformed — diff against v2 and re-check.

- [ ] **Step 7: Commit**

```bash
git add FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/ \
        FenixKanbanTests/Models/CardFizzyAttributesTests.swift \
        FenixKanban.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(fizzy): CoreData v3 — Card.fizzyID/fizzyEtag/fizzyUpdatedAt

Adds three optional attributes for the Fizzy sync engine to track
per-card pairing + ETag + last-seen timestamp. Lightweight
migration from v2; existing data preserved. usedWithCloudKit=YES
preserved on the model root.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

⚠️ Important: include the WHOLE `FenixKanban.xcdatamodeld` directory in the `git add` so both the new model bundle AND the updated `.xccurrentversion` are staged together. If your `make generate` modifies the scheme file, `git checkout HEAD --` it back BEFORE staging.

---

## Task 2: Document Phase 3 in `TDD_IMPLEMENTATION_STATUS.md`

**File:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` — append a new section at the end

- [ ] **Step 1: Append the entry**

Append to the bottom of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown

### Fizzy Integration — Phase 3: CoreData Migration ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- Wrote `CardFizzyAttributesTests` (4 tests) against three not-yet-existing `Card` properties — defaults are nil, and each of `fizzyID` / `fizzyEtag` / `fizzyUpdatedAt` round-trips through save/refresh.
- Verified the tests failed before adding the v3 model (`Value of type 'Card' has no member 'fizzyID'`).

**🟢 Green Phase:**
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/contents` — clone of v2 with three new optional `Card` attributes:
  - `fizzyID: String?` — Fizzy's opaque card ID; `nil` = local-only
  - `fizzyEtag: String?` — last ETag seen for this card (sent on next GET for 304 short-circuit)
  - `fizzyUpdatedAt: Date?` — Fizzy's `last_active_at` from the last successful fetch (drives LWW)
- `.xccurrentversion` bumped to `FenixKanban 3.xcdatamodel`.
- `usedWithCloudKit="YES"` preserved on the root `<model>` element.

**🔵 Refactor Phase:**
- None needed — additive, optional migration; no code changes outside the model.
- v1 and v2 model files preserved for users upgrading from older builds.

**Spec:** `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-fizzy-phase-3-coredata.md`

**Test Coverage:** 4 new tests; full suite green at 173/173 (Phase 2 baseline 169 + Phase 3 added 4).

**CloudKit smoke:** Manual — run the app on a real device or simulator with iCloud Drive enabled, create a card, observe in CloudKit Dashboard (`iCloud.com.bluefenixproductions.FenixKanban` → Schema → Development) that `CD_fizzyID` / `CD_fizzyEtag` / `CD_fizzyUpdatedAt` fields appear on the `CD_Card` record type. Deploy-to-production happens in a single CloudKit Dashboard step before the App Store release that includes any Fizzy sync writes (Phase 5+).

**What ships:** Three optional Card attributes ready for Phase 4's sync engine to read/write. Zero behavior change for users until the engine + UI land.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log Fizzy Phase 3 (CoreData migration v2 → v3)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Final verification

- [ ] **Step 1: Reset simulator + run the full iOS test suite**

```bash
xcrun simctl shutdown all 2>&1 | tail -1
sleep 3
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests \
  test 2>&1 | grep -E "Test run|TEST SUCCEEDED|TEST FAILED" | tail -3
```

Expected: `Test run with 173 tests in ~38 suites passed`. If a test that depends on `Card` regressed, the new model XML is likely malformed.

- [ ] **Step 2: Clean macOS build**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  clean build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 3: Verify the model bundle ships correctly**

```bash
ls FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/
cat FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/.xccurrentversion | grep "<string>"
```

Expected: directory listing includes `FenixKanban 3.xcdatamodel`, and `.xccurrentversion` `<string>` says `FenixKanban 3.xcdatamodel`.

- [ ] **Step 4: Verify final branch state**

```bash
git log --oneline 3ab0321..HEAD
git status -sb
```

Expected: 2 new commits (the v3 model + tests, then the TDD status doc). Clean working tree.

- [ ] **Step 5: Report Phase 3 ready**

Suggested PR title if/when you're ready to push:

> `feat(fizzy): Phase 3 — CoreData migration for fizzyID/fizzyEtag/fizzyUpdatedAt`

Suggested PR body skeleton (do NOT auto-push):

```markdown
## Summary
- New `FenixKanban 3.xcdatamodel` adds three optional `Card` attributes for Fizzy sync state.
- Lightweight migration from v2; existing data preserved.
- 4 new tests; full suite green at 173/173.
- Zero behavior change for users until Phase 4's sync engine + Phase 5's UI land.

## Test plan
- [x] Build clean on iOS Simulator + macOS.
- [x] 4 new Card attribute tests pass (defaults + per-field round-trip).
- [x] Full suite green — no regressions in any existing Card-using test.
- [ ] **Before any App Store release that includes Fizzy sync (Phase 5+):** Open CloudKit Dashboard → Container `iCloud.com.bluefenixproductions.FenixKanban` → Schema → Deploy Schema Changes to Production. Without this step, `fizzyID` / `fizzyEtag` / `fizzyUpdatedAt` sync breaks for App Store users until the dashboard step happens.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-fizzy-phase-3-coredata.md`
```

---

## Success criteria recap

- [ ] `FenixKanban 3.xcdatamodel/contents` exists with three new optional `Card` attributes.
- [ ] `.xccurrentversion` points at `FenixKanban 3.xcdatamodel`.
- [ ] v1 and v2 model files unchanged (chain preserved).
- [ ] 4 `CardFizzyAttributesTests` pass.
- [ ] Full iOS test suite passes (~173 tests).
- [ ] macOS clean build succeeds with no new warnings.
- [ ] `usedWithCloudKit="YES"` preserved on the v3 `<model>` root.
- [ ] `TDD_IMPLEMENTATION_STATUS.md` updated.
- [ ] CloudKit Dashboard deploy step recorded in the PR body as a release-checklist item.
