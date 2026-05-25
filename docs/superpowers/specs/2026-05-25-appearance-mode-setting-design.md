# Appearance Mode Setting — Design

**Date:** 2026-05-25
**Status:** Draft (awaiting user review)
**Author:** Chris Pelatari (with Claude)

## Problem

The app is currently force-locked to dark mode via `.preferredColorScheme(.dark)` at the root `WindowGroup` (`FenixKanbanApp.swift:55`). Users have no way to opt into light mode or follow the OS-level appearance setting. This is a regression vs. platform expectations on iOS 26 / macOS 26 and blocks accessibility for users who prefer light or system-managed appearance.

## Goal

Let users choose between **System**, **Light**, and **Dark** appearance from Settings. The choice persists across launches and is applied immediately app-wide.

## Non-goals

- Per-board or per-view theme overrides.
- Custom themes / brand palettes / accent-color picker.
- Adapting `#Preview` blocks (they remain `.dark` — preview-time only, not user-visible).
- A full light-mode visual audit of every custom color value. The cross-platform color helpers and semantic SwiftUI styles already adapt automatically; any custom RGB values that need a light-mode contrast pass are tracked as a follow-up.

## Architecture

### Component: `AppearanceMode` enum

New file: `FenixKanban/Core/Settings/AppearanceMode.swift`

```swift
import SwiftUI

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

    /// `nil` lets SwiftUI defer to the OS setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
```

**Why a dedicated file under `Core/Settings/`:** keeps the enum, label, and SwiftUI mapping in one focused unit independent of `SettingsView` (which is feature/UI code). A future Shortcuts / App Intent action ("set appearance to light") can import it without pulling in the Settings UI.

### Persistence

`@AppStorage("appearanceMode")` on the raw string value. Default: `AppearanceMode.system.rawValue` = `"system"`.

**Why `@AppStorage` (vs. `UserDefaults` + `didSet`):** matches the established pattern (`hasSkippedAuth` at `FenixKanbanApp.swift:77`) and gives us automatic SwiftUI invalidation — the root view re-renders when the setting changes, no observer wiring needed.

### Application at root

`FenixKanbanApp.swift` `body`:

```swift
@AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue

var body: some Scene {
    WindowGroup {
        ContentView(navigator: navigator)
            // ... existing modifiers ...
            .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
            // ... existing modifiers ...
    }
}
```

Replaces the hard-coded `.preferredColorScheme(.dark)` on line 55. When the mode is `.system`, `colorScheme` is `nil` and SwiftUI follows the OS setting.

### UI: Settings picker

New `Section("Appearance")` in `SettingsView`, placed between `Section("Account")` and `Section("Notifications")` so it's discoverable above the fold.

```swift
@AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue

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

On macOS the default `.menu` picker style is used (segmented pickers in `Form` look out of place on macOS).

## Data flow

```
User taps picker
    ↓
@AppStorage writes "appearanceMode" → UserDefaults
    ↓
SwiftUI invalidates any view reading the same @AppStorage key
    ↓
FenixKanbanApp.body re-renders → .preferredColorScheme(...) updates
    ↓
Entire view hierarchy below WindowGroup re-tints
```

Same key (`"appearanceMode"`) is read in two places (root app + settings picker). Both use `@AppStorage`, so SwiftUI keeps them in sync automatically — no shared view model needed.

## Tests

New file: `FenixKanbanTests/Core/Settings/AppearanceModeTests.swift` (Swift Testing).

1. **`colorScheme` mapping** — verifies `.system → nil`, `.light → .light`, `.dark → .dark`. Locks the SwiftUI contract.
2. **Raw-value round-trip** — `AppearanceMode(rawValue: AppearanceMode.light.rawValue) == .light` for each case. Locks the UserDefaults persistence contract — a typo'd raw value would silently break stored preferences after the next release.
3. **`allCases` order** — asserts `[.system, .light, .dark]`. Locks picker ordering; reordering the enum cases would silently rearrange the UI.
4. **`label` strings** — verifies each case produces the expected user-visible string. Locks the i18n surface (when localization is added later, these tests become the canonical list to translate).

No UI tests required — the picker is one binding to `@AppStorage`; if the mapping tests pass, the wiring is the standard SwiftUI pattern.

## Edge cases

- **Corrupt / missing UserDefaults value:** `AppearanceMode(rawValue:)` returns `nil`, the `?.colorScheme` chain produces `nil`, and the app falls back to system appearance. Safe.
- **App-intent driven change (future):** because both the picker and the root view read the same `@AppStorage` key, a future `SetAppearanceIntent` writing the key via `UserDefaults.standard.set(...)` will update the UI without any extra plumbing.
- **First launch on a system with light mode enabled:** the user sees a light app immediately. This is the intended default per user decision (2026-05-25 — "System").
- **Existing users post-update:** they were on forced-dark before. After update, the default is `system`, so an OS-dark user keeps dark; an OS-light user gets light. Acceptable migration — the new picker is one tap away if they want the old behavior back.

## Risk: custom-color contrast in light mode

`Color+CrossPlatform.swift` already handles backgrounds via semantic colors that adapt automatically. The `goldenTicket` / `goldenTicketIcon` pair uses hard-coded RGB tuned for a dark backdrop. In light mode the dark-brown `goldenTicketIcon` may read poorly on a light card background.

**Mitigation for this change:** the existing `shouldUseIncreasedContrast` branch already supplies darker icon variants when "Increase Contrast" is on, which incidentally helps in light mode too. After implementation, manually verify on macOS in light mode; if the golden tint reads poorly, open a separate follow-up issue. Do not block this change on it.

## Files touched

**New:**
- `FenixKanban/Core/Settings/AppearanceMode.swift`
- `FenixKanbanTests/Core/Settings/AppearanceModeTests.swift`

**Modified:**
- `FenixKanban/FenixKanbanApp.swift` — replace `.preferredColorScheme(.dark)` with `@AppStorage`-driven binding.
- `FenixKanban/Features/Settings/SettingsView.swift` — insert `Section("Appearance")` with picker.
- `TDD_IMPLEMENTATION_STATUS.md` — append entry per project convention.

## Build sequence (TDD)

1. **Red** — write `AppearanceModeTests` first; verify all four tests fail (target type doesn't exist).
2. **Green** — create `AppearanceMode.swift` minimal enough to pass; verify tests pass.
3. **Wire root** — replace `.preferredColorScheme(.dark)` in `FenixKanbanApp.swift`. Build + run on iOS sim and macOS, verify dark→light flip via Xcode environment override behaves as expected.
4. **Wire UI** — add `Section("Appearance")` in `SettingsView`. Build + run, change setting in-app, verify immediate app-wide update.
5. **Status log** — append entry to `TDD_IMPLEMENTATION_STATUS.md`.
6. **CI** — push, confirm `swift-pr-check.yml` passes on both targets.

## Success criteria

- [ ] `swift build` succeeds for both iOS and macOS targets, no warnings.
- [ ] All four `AppearanceModeTests` pass.
- [ ] Full test suite continues to pass (127/127 baseline at time of writing).
- [ ] Picker in Settings → Appearance switches between System / Light / Dark instantly.
- [ ] Setting persists across cold launches.
- [ ] Setting respects OS appearance change when on "System" without app restart.
- [ ] CI green.
