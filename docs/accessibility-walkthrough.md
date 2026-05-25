# Accessibility Walkthrough — Liquid Glass

Apple's [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) guide requires that every screen be visually verified under three accessibility / appearance settings on iOS 26 and macOS 26:

1. **Reduce Transparency** — the Liquid Glass material becomes more solid; previously-translucent chrome may obscure underlying content.
2. **Reduce Motion** — the Liquid Glass shape-morphing and fluid response animations are dampened or removed.
3. **Alternate Liquid Glass appearance** — the system Settings option to swap between the default Liquid Glass and the more saturated alternate appearance.

Standard components adapt automatically; **custom UI does not**. This document captures the FenixKanban walkthrough.

## What custom UI we have to check

| Surface | Custom? | Notes |
|---|---|---|
| `AuthView` window background | No (system) | Post-Liquid-Glass cleanup — relies on system bg |
| `BoardListView` sidebar rows | No (`.listStyle(.sidebar)`) | Post-Liquid-Glass cleanup — relies on sidebar style |
| `BoardListView` row's `BoardRowView` | **Yes** | Per-board hex-color swatch (`RoundedRectangle` fill) + `.primary` text |
| `BoardView` toolbar | No (stock) | Stock SwiftUI toolbar |
| `BoardView` multi-column layout | **Yes** | Custom `ScrollView(.horizontal)` + `LazyHStack` |
| `ColumnView` column container | **Yes** | `.background(Color.crossPlatformSecondarySystemBackground)`, custom `cornerRadius` |
| `ColumnView` card-count badge & "Add Card" pill | **Yes** | `.background(Color.crossPlatformQuaternarySystemFill)` |
| `CardView` card background | **Yes** | Tint based on column color, `RoundedRectangle(cornerRadius: 8)` |
| `LabelBadge` | **Yes** | `Color(hex:).opacity(0.25)` fill |
| `Settings` / `NewColumnSheet` / `NewCardSheet` / `LabelEditorSheet` | No (stock Form) | Stock SwiftUI Form |

The `Color.crossPlatform*` extensions wrap system semantic colors (`UIColor.tertiarySystemBackground`, `NSColor.textBackgroundColor`, etc.) — those **automatically** include increased-contrast variants. **The only colors without automatic adaptation are user-picked hex colors** on boards, columns, and labels — those are inherently the user's responsibility, not the app's.

## How to walk through it on the iOS Simulator

Boot the iPhone 17 (iOS 26) simulator and install FenixKanban first:

```bash
xcrun simctl boot "iPhone 17" 2>&1 | head -1 || true
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app | head -1)
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl spawn "iPhone 17" defaults write com.bluefenixproductions.FenixKanban hasSkippedAuth -bool YES
```

Then toggle each setting and screenshot. Use the existing `simctl ui` commands where they exist, otherwise toggle via the Settings app inside the simulator (Settings → Accessibility).

### 1. Reduce Transparency

```bash
# Toggle on
xcrun simctl ui "iPhone 17" increase_transparency disable  # available in recent Xcode
# OR manually: Simulator → Settings app → Accessibility → Display & Text Size → Reduce Transparency
```

Capture:

```bash
xcrun simctl launch "iPhone 17" com.bluefenixproductions.FenixKanban
sleep 3
xcrun simctl io "iPhone 17" screenshot /tmp/fk-a11y/01-reduce-transparency-boardlist.png
# Navigate manually to: Board, Settings, TipJar — screenshot each
```

**Check:** Toolbar group capsules, list rows, card tints, and column backgrounds remain legible. Text is not lost against now-solid Liquid Glass surfaces. Board color swatch (user-picked) is still distinguishable from its row background.

### 2. Reduce Motion

```bash
# Toggle on via Settings app inside the sim:
# Settings → Accessibility → Motion → Reduce Motion → ON
```

**Check:** Sheets present/dismiss with crossfade rather than slide. Tab/page carousel on iPhone portrait still navigates. No essential UI feedback was conveyed only through motion (e.g., a button "pulsing" to indicate state — replace with a label or color shift if so).

### 3. Alternate Liquid Glass appearance

```bash
# Settings → Display & Brightness (or system equivalent) → Appearance → Alternate
# Note: this option's exact location may vary by iOS 26.x point release
```

**Check:** All toolbar / list / sheet chrome renders correctly under the alternate appearance. Custom backgrounds (cards, columns, label badges) read against both appearances without becoming unreadable.

## How to walk through it on macOS

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug/FenixKanban.app | head -1)
open "$APP"
```

System Preferences → Accessibility → Display:
- Toggle **Reduce Transparency** and verify each screen.
- Toggle **Reduce Motion** and verify each screen.

System Preferences → Appearance (or wherever iOS 26's setting moved):
- Toggle the alternate Liquid Glass appearance and verify each screen.

## What to do if a regression is found

- **Stock SwiftUI surface looks wrong:** that's an Apple bug — file via Feedback Assistant, do not work around it locally.
- **Custom surface (`ColumnView`, `CardView`, `LabelBadge`, `BoardRowView` swatch) looks wrong:**
  - If text becomes unreadable on a tinted background → add a `.foregroundStyle(.primary)` override or, for user-picked colors, gate the background opacity behind `@Environment(\.colorSchemeContrast)` to fade the tint when `.increased`.
  - If a corner radius reads wrong against the system shape language → consider switching from a hard-coded `cornerRadius` to a SwiftUI-derived value (e.g., `RoundedRectangle(cornerSize: .init(width: 12, height: 12), style: .continuous)`).
  - If a card/column blends into the background → adjust the `Color.crossPlatform*` helper rather than the consumer.

## Status

This walkthrough is the manual-verification step of [`docs/superpowers/specs/2026-05-25-liquid-glass-adoption-design.md`](superpowers/specs/2026-05-25-liquid-glass-adoption-design.md)'s full-scope follow-up. Run it after any meaningful UI change. Record the date + verdict + simulator/build versions when complete:

| Date | Verdict | Notes |
|---|---|---|
| _pending first walkthrough_ | — | — |
