# Liquid Glass Minimal Adoption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the few view modifiers in FenixKanban that fight Liquid Glass on iOS 26 / macOS 26, then let stock SwiftUI components pick up the new system appearance automatically.

**Architecture:** Pure deletion sweep. Each change removes a `.background(...)` or `.listRowBackground(...)` on a navigation/chrome surface that is suppressing the Liquid Glass appearance. Content surfaces (cards, columns, label badges) are intentionally left alone. No new APIs are introduced — this is the "minimal" tier of the three-tier adoption path described in the spec.

**Tech Stack:** Swift 5.9 / SwiftUI / xcodegen / Swift Testing (XCTest replaced in 2e8c0fe). Deployment targets iOS 26.0 / macOS 26.0.

**Spec:** [`docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md`](../specs/2026-05-25-liquid-glass-adoption-design.md)

**Note on TDD:** This plan does NOT follow strict red-green-refactor because the changes are pure deletions of view modifiers — there is no new behavior to assert. The 78-test regression suite serves as the safety net, and Task 5 (visual verification on the iOS 26 simulator) is the closest thing to an acceptance test for "renders with Liquid Glass." This deviation from the project's standard TDD workflow is intentional and noted in the TDD_IMPLEMENTATION_STATUS.md update in Task 6.

---

## File Structure

**Files modified:**
- `FenixKanban/Features/Auth/AuthView.swift` — remove platform-conditional window background block (5 lines).
- `FenixKanban/Features/BoardList/BoardListView.swift` — remove one `.listRowBackground(...)` line.
- `TDD_IMPLEMENTATION_STATUS.md` — append a "Liquid Glass Minimal Adoption" section per the repo's TDD-status-tracking rule.

**Files verified, NOT modified:**
- `FenixKanban/Features/TipJar/TipJarView.swift` — `.listRowBackground(Color.clear)` at line 29 stays (it removes a default background; Liquid Glass shows through cleanly).

**No new files.**

---

### Task 1: Remove AuthView's window background

The `AuthView` fills the window/screen. On iOS 26 / macOS 26 the system supplies the correct window background automatically; imposing a custom `Color(uiColor:/nsColor: ...)` background on top of that suppresses Liquid Glass.

**Files:**
- Modify: `FenixKanban/Features/Auth/AuthView.swift:58-63`

- [ ] **Step 1: Confirm current state of the modifier block**

Run: `sed -n '55,65p' FenixKanban/Features/Auth/AuthView.swift`

Expected output:

```swift
            Spacer()
                .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
}
```

If output differs from this, STOP — the file has drifted and the next step's edit will not apply cleanly.

- [ ] **Step 2: Delete the platform-conditional `.background(...)` block**

Use the Edit tool with these exact strings:

`old_string`:

```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
}
```

`new_string`:

```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

The 5 lines between `.frame(...)` and the closing `}` are removed.

- [ ] **Step 3: Build for iOS 26 simulator**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

If the build fails with `Cannot find 'Color' in scope` or similar, the edit removed something it shouldn't have — restore via `git checkout HEAD -- FenixKanban/Features/Auth/AuthView.swift` and re-attempt.

- [ ] **Step 4: Build for macOS**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

This is the higher-risk platform check because the macOS branch (`Color(nsColor: .windowBackgroundColor)`) was specifically the one some developers add to "make sure the window isn't transparent." If macOS rendering regresses visually in Task 5, the spec's risk mitigation applies (re-add the modifier wrapped in `#if os(macOS)` only).

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/Auth/AuthView.swift
git commit -m "$(cat <<'EOF'
feat: remove AuthView window background to enable Liquid Glass

The platform-conditional .background(Color(uiColor:/nsColor: ...)) at the
top level of AuthView was suppressing the iOS 26 / macOS 26 Liquid Glass
system window background. Standard SwiftUI views fill the window with the
system-supplied background automatically when no custom one is imposed.

Part of the minimal Liquid Glass adoption sweep (see
docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md).
EOF
)"
```

---

### Task 2: Remove BoardListView's per-row background

`BoardListView`'s sidebar list rows have an explicit `.listRowBackground(Color.crossPlatformSecondarySystemBackground)`. On iOS 26, list rows pick up the Liquid Glass appearance from the parent `.listStyle(.sidebar)` automatically; imposing a custom row background suppresses that.

Board identity is conveyed by the per-board color swatch inside `BoardRowView` itself, so removing the row-background tint does not lose information.

**Files:**
- Modify: `FenixKanban/Features/BoardList/BoardListView.swift:133`

- [ ] **Step 1: Confirm current state of the line**

Run: `sed -n '128,136p' FenixKanban/Features/BoardList/BoardListView.swift`

Expected output (line numbers may shift by one or two — match on content):

```swift
                // NavigationLink(value:) is the canonical pattern for
                // NavigationSplitView sidebars — pairs with the selection
                // binding to update the detail column on tap.
                NavigationLink(value: board.objectID) {
                    BoardRowView(board: board)
                }
                .listRowBackground(Color.crossPlatformSecondarySystemBackground)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
```

If the `.listRowBackground(...)` line is absent or different, STOP and reconcile before proceeding.

- [ ] **Step 2: Delete the `.listRowBackground(...)` modifier**

Use the Edit tool:

`old_string`:

```swift
                NavigationLink(value: board.objectID) {
                    BoardRowView(board: board)
                }
                .listRowBackground(Color.crossPlatformSecondarySystemBackground)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
```

`new_string`:

```swift
                NavigationLink(value: board.objectID) {
                    BoardRowView(board: board)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
```

One line is removed.

- [ ] **Step 3: Build for iOS 26 simulator**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Build for macOS**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FenixKanban/Features/BoardList/BoardListView.swift
git commit -m "$(cat <<'EOF'
feat: remove BoardListView row tint to enable Liquid Glass

Sidebar list rows pick up the Liquid Glass appearance from
.listStyle(.sidebar) automatically on iOS 26 / macOS 26. The custom
.listRowBackground(Color.crossPlatformSecondarySystemBackground) was
suppressing that. Board identity is still conveyed by the per-board
color swatch inside BoardRowView.

Part of the minimal Liquid Glass adoption sweep (see
docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md).
EOF
)"
```

---

### Task 3: Verify TipJarView's explicit clear background stays

`TipJarView` has `.listRowBackground(Color.clear)` on the centered-`ProgressView` row at line 29. This *removes* the default background rather than *imposing* one — Liquid Glass shows through cleanly. The spec calls for **no change** here; this task confirms that.

**Files:**
- Verify (no edit): `FenixKanban/Features/TipJar/TipJarView.swift:29`

- [ ] **Step 1: Confirm the line is still present and unchanged**

Run: `sed -n '22,32p' FenixKanban/Features/TipJar/TipJarView.swift`

Expected output (line numbers may shift by one or two):

```swift
            Section("Choose a Tip") {
                if store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if store.tips.isEmpty {
                    Text("Tip options unavailable right now.")
                        .foregroundStyle(.secondary)
```

If `.listRowBackground(Color.clear)` is absent, the file has drifted from the state the spec was written against — STOP and reconcile with the user.

- [ ] **Step 2: Mark verified — no commit, no edit**

This task changes no files. Continue to Task 4.

---

### Task 4: Regression — run the full test suite

The minimal-sweep changes are pure view-modifier deletions, so all 78 automated tests must continue to pass. A regression here means one of the deleted modifiers was load-bearing for something the spec did not anticipate.

**Files:**
- None modified.

- [ ] **Step 1: Run the iOS test suite**

Run: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E "Test run with|TEST" | tail -3`

Expected output (the count line is the key one):

```
✔ Test run with 78 tests in 14 suites passed after <N>s.
** TEST SUCCEEDED **
```

- [ ] **Step 2: If the count is not 78, investigate**

A lower count means tests were silently skipped or didn't compile; a higher count means new tests were added since the spec. Either way, STOP and reconcile before proceeding to Task 5.

- [ ] **Step 3: No commit (tests are read-only here)**

Continue to Task 5.

---

### Task 5: Visual verification on iOS 26 simulator

This is the closest thing to an acceptance test for "renders with Liquid Glass." The deleted modifiers were chosen because they suppress the new system appearance; here we confirm by eye that the new appearance is now in place.

**Files:**
- None modified.

- [ ] **Step 1: Boot the iPhone 17 simulator**

Run: `xcrun simctl boot "iPhone 17" 2>/dev/null || true; open -a Simulator`

The `|| true` swallows the "already booted" error if the device is up from earlier test runs.

- [ ] **Step 2: Install the freshly-built app onto the simulator**

Find the most recent build product:

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app 2>/dev/null | head -1)
echo "$APP"
```

Expected: a path ending in `FenixKanban.app`. If empty, run a Debug build for the simulator first: `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build`.

Install:

```bash
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl launch "iPhone 17" com.bluefenixproductions.FenixKanban
```

- [ ] **Step 3: Capture the AuthView screen**

```bash
mkdir -p /tmp/fenixkanban-liquid-glass
xcrun simctl io "iPhone 17" screenshot /tmp/fenixkanban-liquid-glass/01-auth.png
```

Open `/tmp/fenixkanban-liquid-glass/01-auth.png`. Confirm: the window background reads as the iOS 26 system background, *not* a flat color block. The "Sign in with Apple" button is fully visible; the FenixKanban title is legible.

- [ ] **Step 4: Walk into the app and capture BoardListView**

In the simulator: tap "Continue without signing in" (or the system Sign-In flow). When the BoardList sidebar appears, screenshot:

```bash
xcrun simctl io "iPhone 17" screenshot /tmp/fenixkanban-liquid-glass/02-boardlist.png
```

Confirm: list rows render with the Liquid Glass row appearance (not a flat secondary-system-background tint). Per-board color swatch is still visible on each row.

- [ ] **Step 5: Capture Settings and TipJar**

In the simulator: open Settings (gear icon, typical placement). Screenshot:

```bash
xcrun simctl io "iPhone 17" screenshot /tmp/fenixkanban-liquid-glass/03-settings.png
```

Confirm: section headers ("Account", "Notifications", "Data", etc.) render in title-case. List rows have the Liquid Glass appearance.

From Settings, navigate to TipJar (or wherever it's surfaced). Screenshot:

```bash
xcrun simctl io "iPhone 17" screenshot /tmp/fenixkanban-liquid-glass/04-tipjar.png
```

Confirm: the loading state (if visible) shows a centered ProgressView with the Liquid Glass row showing through (no flat opaque row); tip rows render with the Liquid Glass appearance.

- [ ] **Step 6: Compare against pre-change baseline (optional but recommended)**

If git history makes it easy, stash the changes temporarily, rebuild, capture the same 4 screenshots into `/tmp/fenixkanban-liquid-glass-before/`, then `git stash pop`. Side-by-side comparison makes any regression obvious.

```bash
# Only if you want a before/after; otherwise skip.
git stash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
mkdir -p /tmp/fenixkanban-liquid-glass-before
xcrun simctl install "iPhone 17" "$APP"
# ... capture 4 screenshots into the -before/ directory ...
git stash pop
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install "iPhone 17" "$APP"
```

- [ ] **Step 7: If any screen regresses visually, STOP**

The spec's risk mitigation paths are:

- **AuthView reads wrong on macOS:** re-add `.background(Color(nsColor: .windowBackgroundColor))` wrapped in `#if os(macOS)` only.
- **BoardList rows become hard to read:** reinstate `.listRowBackground(...)` as the last resort; first try `.listRowBackground(Color.clear)` to see if `.listStyle(.sidebar)`'s default is the actual problem.

If everything reads correctly, continue to Task 6.

- [ ] **Step 8: No commit (verification is read-only)**

Continue to Task 6.

---

### Task 6: Update `TDD_IMPLEMENTATION_STATUS.md` per the repo rule

The repo rule (saved as a Claude memory) requires updating `TDD_IMPLEMENTATION_STATUS.md` after every code task. This adoption sweep is a code task even though it's a deletion-only one.

**Files:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` (append a new section)

- [ ] **Step 1: Append the new section**

Use the Edit tool to add a new H2 section at the end of the file. The current last line of the file is approximately:

```markdown
This research is recorded into global Claude memory as well so future sessions can apply these
rules without re-reading the source docs.
```

Edit with:

`old_string`:

```
This research is recorded into global Claude memory as well so future sessions can apply these
rules without re-reading the source docs.
```

`new_string`:

```
This research is recorded into global Claude memory as well so future sessions can apply these
rules without re-reading the source docs.

---

## 🪟 May 25, 2026 — Liquid Glass Minimal Adoption

Minimal-sweep adoption of Liquid Glass on iOS 26 / macOS 26 per
[`docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md`](docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md)
and executed via
[`docs/superpowers/plans/2026-05-25-liquid-glass-adoption.md`](docs/superpowers/plans/2026-05-25-liquid-glass-adoption.md).

**Changes:**

- `AuthView.swift`: removed the platform-conditional `.background(Color(uiColor:/nsColor: ...))` at the top level. The system window background now applies, allowing Liquid Glass to render.
- `BoardListView.swift`: removed `.listRowBackground(Color.crossPlatformSecondarySystemBackground)` from the sidebar rows. `.listStyle(.sidebar)` now controls the row appearance; per-board identity remains via the color swatch in `BoardRowView`.
- `TipJarView.swift`: verified `.listRowBackground(Color.clear)` stays — it removes a background rather than imposing one, so Liquid Glass shows through.

**Workflow note (deviation from project TDD):** This adoption sweep did NOT follow strict red-green-refactor because the changes are pure view-modifier deletions with no new behavior to assert. The 78-test regression suite was the safety net; visual verification on the iPhone 17 simulator was the acceptance criterion. This deviation is intentional and bounded to view-modifier deletions only — new logic continues to follow the project's TDD workflow.

**Out-of-scope follow-ups still tracked:**

1. Moderate-scope sweep — wrap custom content surfaces (card tints, column "Add Card" pill) in `.glassEffect(.regular, in: ...)` / `GlassEffectContainer` for native Liquid Glass on content.
2. Full-scope sweep — add increased-contrast variants for every custom color; walk every screen under reduce-transparency, reduce-motion, and the alternate Liquid Glass appearance.
3. App icon rebuild in Icon Composer with layered semi-transparent shapes (design task).
4. App Intents + Core Spotlight adoption — high-leverage hook into Siri / Shortcuts / Apple Intelligence / Visual Intelligence.
```

- [ ] **Step 2: Commit**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs: record Liquid Glass minimal adoption in TDD status

Per the repo's TDD-status-tracking rule, append a section to
TDD_IMPLEMENTATION_STATUS.md summarizing today's Liquid Glass
minimal sweep. Notes the deviation from strict red-green-refactor
(the changes are view-modifier deletions; the 78-test regression
suite is the safety net) and tracks the moderate / full / icon /
App Intents follow-ups as out-of-scope future work.
EOF
)"
```

- [ ] **Step 3: Final verification**

Run:

```bash
git status
git log --oneline -5
```

Expected: `git status` shows a clean working tree. `git log` shows 3 new commits (one per Task 1, Task 2, and Task 6), all signed `Co-Authored-By: Claude` per project convention. No uncommitted changes from Tasks 3, 4, or 5 (they were verification-only).

---

## Self-review notes

**Spec coverage:** every change in the spec maps to a task:
- Spec §Changes/1 (AuthView) → Task 1
- Spec §Changes/2 (BoardListView) → Task 2
- Spec §Changes/3 (TipJarView, no change) → Task 3
- Spec §Changes/4 (verification pass: section headers, toolbars, builds, tests) → builds in Tasks 1+2, tests in Task 4, manual checks in Task 5
- Spec §Test Plan → Tasks 4 and 5
- Spec §Risks & Mitigations → wired into Task 5 Step 7

**Placeholder scan:** no TBDs, no "implement appropriate error handling," no "similar to Task N" — every step has exact commands and exact code.

**Type consistency:** No new types introduced; only deletions. Existing identifiers (`Color.crossPlatformSecondarySystemBackground`, `BoardRowView`, `.listStyle(.sidebar)`) are referenced consistently between spec and plan.
