# Appearance Mode Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a System / Light / Dark appearance picker in Settings, replacing the hard-coded `.preferredColorScheme(.dark)` at the app root. Default is System.

**Architecture:** A new `AppearanceMode` enum (in `Core/Settings/`) maps the user's choice to an optional `ColorScheme`. The choice is persisted via `@AppStorage("appearanceMode")` and read in two places — the root `WindowGroup` and the new picker in `SettingsView`. SwiftUI's `@AppStorage` invalidation keeps both in sync automatically.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test` macro), `@AppStorage`, XcodeGen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-05-25-appearance-mode-setting-design.md`

---

## File Structure

**New files:**
- `FenixKanban/Core/Settings/AppearanceMode.swift` — enum + label + ColorScheme mapping. ~25 LOC.
- `FenixKanbanTests/Core/Settings/AppearanceModeTests.swift` — 4 unit tests locking the contract. ~40 LOC.

**Modified files:**
- `FenixKanban/FenixKanbanApp.swift` — swap forced `.preferredColorScheme(.dark)` for `@AppStorage`-driven binding.
- `FenixKanban/Features/Settings/SettingsView.swift` — insert `Section("Appearance")` with `Picker`.
- `TDD_IMPLEMENTATION_STATUS.md` — append progress entry per project convention.

**Project regen:** `project.yml` already sources `FenixKanban` and `FenixKanbanTests` recursively, so no `project.yml` edits are needed — but `make generate` (XcodeGen) must run after adding files so they appear in the `.xcodeproj`.

---

## Task 1: Failing test for `AppearanceMode`

**Files:**
- Create: `FenixKanbanTests/Core/Settings/AppearanceModeTests.swift`

- [ ] **Step 1: Create the test file**

```swift
import Testing
import SwiftUI
@testable import FenixKanban

@Suite("AppearanceMode")
struct AppearanceModeTests {

    @Test("colorScheme maps system→nil, light→.light, dark→.dark")
    func colorSchemeMapping() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    @Test("raw value round-trips for every case")
    func rawValueRoundTrip() {
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test("allCases ordering is system, light, dark")
    func allCasesOrder() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
    }

    @Test("label strings are user-visible names")
    func labels() {
        #expect(AppearanceMode.system.label == "System")
        #expect(AppearanceMode.light.label == "Light")
        #expect(AppearanceMode.dark.label == "Dark")
    }
}
```

- [ ] **Step 2: Regenerate Xcode project to pick up the new file**

Run:
```bash
make generate
```

Expected: `xcodegen generate` completes with no errors.

- [ ] **Step 3: Run the new tests and verify they fail**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/AppearanceModeTests \
  test 2>&1 | tail -40
```

Expected: build fails with `cannot find 'AppearanceMode' in scope` (red phase — the type doesn't exist yet).

- [ ] **Step 4: Commit the failing test**

```bash
git add FenixKanbanTests/Core/Settings/AppearanceModeTests.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
test(appearance): failing tests for AppearanceMode enum

Red phase per CLAUDE.md TDD workflow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `AppearanceMode` (green)

**Files:**
- Create: `FenixKanban/Core/Settings/AppearanceMode.swift`

- [ ] **Step 1: Create the enum**

```swift
import SwiftUI

/// User-selectable appearance mode persisted via `@AppStorage("appearanceMode")`.
///
/// `.system` maps to `nil`, which lets SwiftUI defer to the OS-level
/// `ColorScheme`. `.light` / `.dark` force the corresponding scheme on
/// the entire view hierarchy below the root `WindowGroup`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
```

- [ ] **Step 2: Regenerate Xcode project**

Run:
```bash
make generate
```

Expected: success.

- [ ] **Step 3: Run the tests and verify they pass**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FenixKanbanTests/AppearanceModeTests \
  test 2>&1 | tail -20
```

Expected: 4 tests pass, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FenixKanban/Core/Settings/AppearanceMode.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
feat(appearance): AppearanceMode enum with system/light/dark cases

Green phase. Maps user choice to optional ColorScheme; .system → nil
defers to OS appearance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `@AppStorage` at the WindowGroup root

**Files:**
- Modify: `FenixKanban/FenixKanbanApp.swift` (line 55 — the `.preferredColorScheme(.dark)` modifier; struct body around lines 49–67)

- [ ] **Step 1: Add the `@AppStorage` property on `FenixKanbanApp`**

In `FenixKanbanApp.swift`, just after `@State private var navigator = NavigationModel()` (around line 11), add:

```swift
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
```

- [ ] **Step 2: Replace the forced `.preferredColorScheme(.dark)`**

Find this line (currently line 55):

```swift
                .preferredColorScheme(.dark)
```

Replace with:

```swift
                .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
```

- [ ] **Step 3: Build both targets and confirm no warnings**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build 2>&1 | tail -10
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  build 2>&1 | tail -10
```

Expected: both end with `** BUILD SUCCEEDED **` and no warnings introduced by these changes.

- [ ] **Step 4: Run the full test suite to confirm no regressions**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -30
```

Expected: full suite passes (baseline 127/127 + new 4 = 131/131). If a previously-passing test that asserted on dark-mode-specific UI fails, that's a real regression — fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/FenixKanbanApp.swift
git commit -m "$(cat <<'EOF'
feat(appearance): drive root colorScheme from @AppStorage

Replaces hard-coded .preferredColorScheme(.dark) on the root
WindowGroup with a binding to AppearanceMode. Default is .system,
so users on light-mode OS now see light by default.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add the picker in Settings

**Files:**
- Modify: `FenixKanban/Features/Settings/SettingsView.swift` (insert a new section between line 46 — end of `Account` section — and line 48 — start of `Notifications` section)

- [ ] **Step 1: Add the `@AppStorage` property to `SettingsView`**

In `SettingsView`, after `@Environment(\.managedObjectContext) private var context` (line 6), add:

```swift
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
```

- [ ] **Step 2: Insert the Appearance section**

Find the end of `Section("Account") { ... }` (closing `}` at line 46) and the start of `Section("Notifications") { ... }` (line 48). Between them, insert:

```swift
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.segmented)
                    #endif
                }
```

(On macOS the default `.menu` picker style is used — segmented pickers inside a `Form` row look out of place there.)

- [ ] **Step 3: Build both targets**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build 2>&1 | tail -10
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  build 2>&1 | tail -10
```

Expected: both succeed.

- [ ] **Step 4: Manual smoke test on iOS simulator**

Run:
```bash
make run
```

Then in the running app:
1. Open Settings (gear icon).
2. In the new "Appearance" section, tap each segment: System / Light / Dark.
3. Confirm the app re-tints immediately on each tap.
4. Force-quit and relaunch; the selection should persist.
5. With "System" selected, change the simulator's appearance (Features → Toggle Appearance) and confirm the app follows without a restart.

Expected: all five behaviors work. If any don't, do NOT proceed — diagnose first (most likely cause: `@AppStorage` key typo'd between the two call sites).

- [ ] **Step 5: Run the full test suite**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -30
```

Expected: 131/131 passing.

- [ ] **Step 6: Commit**

```bash
git add FenixKanban/Features/Settings/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat(appearance): Settings picker for System/Light/Dark

New "Appearance" section in Settings backed by the same @AppStorage
key the root WindowGroup reads. Segmented control on iOS, default
menu picker on macOS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Document in `TDD_IMPLEMENTATION_STATUS.md`

**Files:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` (append a new section)

- [ ] **Step 1: Append the progress entry**

At the end of `TDD_IMPLEMENTATION_STATUS.md`, append:

```markdown

### Appearance Mode Setting ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-25

**🔴 Red Phase:**
- Created `FenixKanbanTests/Core/Settings/AppearanceModeTests.swift` with 4 tests covering colorScheme mapping, raw-value round-trip, `allCases` ordering, and label strings.
- Verified failing build (`cannot find 'AppearanceMode' in scope`).

**🟢 Green Phase:**
- Created `FenixKanban/Core/Settings/AppearanceMode.swift` — enum with `system`/`light`/`dark` cases; maps to optional `ColorScheme` (`.system → nil` defers to OS).
- All 4 tests pass.

**🔵 Refactor Phase:**
- `FenixKanban/FenixKanbanApp.swift`: replaced hard-coded `.preferredColorScheme(.dark)` with `@AppStorage("appearanceMode")`-driven binding.
- `FenixKanban/Features/Settings/SettingsView.swift`: added `Section("Appearance")` with `Picker` (segmented on iOS, default menu on macOS).
- Default is `.system`; setting persists via `@AppStorage` and updates immediately when changed.

**Spec:** `docs/superpowers/specs/2026-05-25-appearance-mode-setting-design.md`
**Plan:** `docs/superpowers/plans/2026-05-25-appearance-mode-setting.md`

**Test Coverage:** 4/4 new tests; full suite 131/131.

**Follow-up:** Light-mode contrast audit for `goldenTicket`/`goldenTicketIcon` (`Color+CrossPlatform.swift:55-85`) — flagged in spec, not blocking.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log appearance-mode setting in implementation status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final verification

- [ ] **Step 1: Run the full test suite on iOS**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -30
```

Expected: 131/131 passing, `** TEST SUCCEEDED **`.

- [ ] **Step 2: Build macOS target clean**

Run:
```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' \
  clean build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 3: Manual smoke test on macOS**

Open the built `.app` from Xcode (`⌘R` against the macOS destination) and:
1. Open Settings.
2. Switch between System / Light / Dark via the menu picker.
3. Confirm window chrome and content both re-tint.
4. Quit and relaunch — selection persists.

Expected: matches iOS behavior. If macOS picker style looks wrong, this is the moment to switch to a different style (e.g., `.inline`) before merging.

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin develop
gh pr create --title "feat(appearance): user-selectable System/Light/Dark mode" --body "$(cat <<'EOF'
## Summary
- Adds an Appearance picker in Settings (System / Light / Dark).
- Replaces forced `.preferredColorScheme(.dark)` at the root with `@AppStorage`-driven binding.
- Default is System; existing users on light-mode OS will now see light.

## Test plan
- [x] 4 new Swift Testing cases for `AppearanceMode` enum (mapping, round-trip, ordering, labels).
- [x] Full suite 131/131 on iOS Simulator.
- [x] macOS build clean, no warnings.
- [x] Manual smoke: picker switches immediately, persists across launch, follows OS when on System.

## Spec / Plan
- Spec: `docs/superpowers/specs/2026-05-25-appearance-mode-setting-design.md`
- Plan: `docs/superpowers/plans/2026-05-25-appearance-mode-setting.md`

## Follow-up (not in this PR)
- Light-mode contrast audit for golden-ticket card colors (`Color+CrossPlatform.swift:55-85`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed; CI (`swift-pr-check.yml`) starts and goes green.

---

## Success criteria recap

- [ ] `AppearanceMode` enum exists with `system`/`light`/`dark` cases.
- [ ] 4 `AppearanceModeTests` pass.
- [ ] Full suite passes (131/131).
- [ ] iOS Simulator and macOS targets build clean, no warnings.
- [ ] Picker in Settings switches appearance instantly.
- [ ] Selection persists across cold launches.
- [ ] "System" follows OS appearance changes without restart.
- [ ] CI passes on the PR.
- [ ] `TDD_IMPLEMENTATION_STATUS.md` updated.
