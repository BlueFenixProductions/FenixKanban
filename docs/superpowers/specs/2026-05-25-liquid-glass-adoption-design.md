# Liquid Glass Minimal Adoption — Design

**Date:** 2026-05-25
**Scope:** Minimal sweep — strip what fights Liquid Glass; introduce no new APIs.
**Target platforms:** iOS 26.0, macOS 26.0 (already set in `project.yml`).

## Background

iOS 26 and macOS 26 introduce **Liquid Glass** as the system-wide dynamic material for chrome (tab bars, toolbars, sidebars, sheets, popovers, list rows, navigation). Standard SwiftUI / UIKit / AppKit components opt into Liquid Glass automatically when the app rebuilds against the latest SDKs. Custom `.background(...)` modifiers on those surfaces, hand-rolled blur effects, and explicit list row backgrounds **interfere with the system appearance** — they sit on top of the new scroll-edge effect and suppress the dynamic morphing the user expects.

This spec captures the minimal-sweep adoption path: remove the things in FenixKanban that fight Liquid Glass, then let stock components do their job. New APIs (`.glassEffect`, `GlassEffectContainer`) and accessibility-variant work are explicitly deferred.

Full background and the broader adoption rules are archived at [`docs/apple-technology-overviews.md`](../../apple-technology-overviews.md).

## Goals

- Stock SwiftUI navigation chrome (lists, sheets, toolbars, sidebar) renders with the iOS 26 / macOS 26 Liquid Glass appearance with no per-screen customization.
- The existing test suite continues to pass (78 tests in 14 suites, Swift Testing).
- No regressions in content surfaces that intentionally use custom tints (cards, columns, label badges).
- macOS and iOS builds still succeed.

## Non-Goals

- Introducing `.glassEffect(...)` / `GlassEffectContainer` on custom content surfaces — that's the moderate-scope follow-up.
- Adding increased-contrast color variants or auditing every screen under reduce-transparency / reduce-motion / alternate appearance — that's the full-scope follow-up.
- Rebuilding the app icon in Icon Composer — design task, separate concern.
- Adopting App Intents / Core Spotlight — separate, larger feature work.
- Touching `ColumnView`, `CardView`, `LabelBadge` chrome — these are *content* surfaces, not navigation, and their custom backgrounds are intentional product identity.

## Changes

### 1. `FenixKanban/Features/Auth/AuthView.swift`

**Current state (lines 58–63):**

```swift
.frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(iOS)
.background(Color(uiColor: .systemBackground))
#elseif os(macOS)
.background(Color(nsColor: .windowBackgroundColor))
#endif
```

**Change:** Delete the platform-conditional `.background(...)`. AuthView fills the window/screen; the system already supplies the correct background. Imposing one suppresses Liquid Glass.

**After:**

```swift
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

The `#if os(iOS)` / `#elseif os(macOS)` block is removed entirely. This removes 5 lines.

### 2. `FenixKanban/Features/BoardList/BoardListView.swift`

**Current state (line 133):**

```swift
.listRowBackground(Color.crossPlatformSecondarySystemBackground)
```

**Change:** Delete this line. List rows should pick up the Liquid Glass appearance from the parent `List` / sidebar style. Board identity is already conveyed by `BoardRowView`'s `colorHex` swatch — the row background tint is redundant.

### 3. `FenixKanban/Features/TipJar/TipJarView.swift` — verified, **no change**

**Line 29** has `.listRowBackground(Color.clear)`. This *removes* the default row background so the centered `ProgressView` row reads as a single empty space rather than a list row. Liquid Glass shows through cleanly. Leave as is.

### 4. Verification pass — no code change unless needed

- **Section headers:** `grep -rn 'Section("' FenixKanban` shows only title-case strings ("Account", "Notifications", "Card Title", "Column Color", "Choose a Tip", etc.). No ALL-CAPS strings. No change required.
- **`ToolbarItem`s:** Spot-checked — all use proper SwiftUI placements (`.primaryAction`, `.cancellationAction`, `.confirmationAction`, `.navigationBarLeading` inside `#if os(iOS)`). No content-only hiding patterns. No change required.
- **Build:** `xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 17' build` must succeed.
- **macOS build:** `xcodebuild ... -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` must succeed.
- **Tests:** `xcodebuild ... test` on iOS 26 simulator must show **78 tests in 14 suites passed**.

## Risks & Mitigations

- **Risk:** AuthView reads "wrong" on macOS because window doesn't get a background.
  - **Mitigation:** Stock macOS windows have `NSColor.windowBackgroundColor` applied automatically by the window machinery; removing the inner `.background(...)` does not produce a transparent window. If the visual is wrong, the fix is to re-add the modifier wrapped in `#if os(macOS)` only — but this is unlikely.
- **Risk:** Board list rows become harder to read against the Liquid Glass row appearance.
  - **Mitigation:** Liquid Glass row appearance is contrast-tuned by the system. The `BoardRowView` text color and the per-board color swatch carry the identity. If a regression is observed, the row background can be reinstated, but this should be the last resort, not the first.

## Test Plan

- All existing automated tests must continue to pass (78 tests, 14 suites, Swift Testing). The changes are purely view-modifier deletions; no logic changes, no test changes required.
- **Manual verification on iOS 26 simulator (iPhone 17):**
  1. Launch app → AuthView appears with system Liquid Glass background.
  2. Sign in / skip → BoardList sidebar renders with Liquid Glass row appearance.
  3. Open a board → toolbar, column chrome, sheets all render with Liquid Glass.
  4. Settings → sections render with title-case headers and Liquid Glass list rows.
  5. TipJar → list rows and ProgressView render cleanly.
- **macOS build only** (runtime test gated on CloudKit entitlement, not in scope): `xcodebuild ... -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` must succeed.

## Out-of-Scope Follow-Ups

Tracked here so they're not forgotten:

- **Moderate-scope sweep:** wrap card tint / column "Add Card" pill in `.glassEffect(.regular, in: ...)` or `GlassEffectContainer` for native Liquid Glass on content surfaces.
- **Full-scope sweep:** add increased-contrast variants for every custom color; walk every screen under reduce-transparency, reduce-motion, alternate Liquid Glass appearance.
- **App icon:** rebuild in Icon Composer with layered semi-transparent shapes; provide light/dark/clear/tinted variants.
- **App Intents + Core Spotlight:** model boards and cards as `AppEntity`, expose actions as `AppIntent`, index for Spotlight — unlocks Siri / Shortcuts / Apple Intelligence / Visual Intelligence integration.
