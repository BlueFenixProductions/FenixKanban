# Splash Screen — Session Handoff

**Saved:** 2026-05-27
**Branch:** `develop` (clean, ahead of `origin/develop` by 24 commits at write time)
**Status:** Shipped. No follow-up needed for the splash itself.

> The pre-existing `.planning/HANDOFF.md` (Fizzy Phase 5 UAT pause) is **unchanged** and still the live resume-from point. This file documents the splash side-quest that happened on top of it.

---

## What was built

Static iOS launch screen via `LaunchScreen.storyboard`:
- Solid contrasting background (`SplashBackground.colorset` — `#F2F2F7` light, `#1C1C1E` dark)
- App icon centered at 200×200 pt, rendered as a rounded tile (`cornerRadius` 45 via storyboard `<layer>` element, not runtime attributes — launch screens forbid those)
- iOS only; excluded from the macOS SDK via `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`
- No SwiftUI overlay, no animation. macOS launches directly into `ContentView`.

## How we got here (the design pivot)

The original plan was an animated SwiftUI splash (pulse + crossfade) that handed off pixel-aligned from the system launch screen. Built and shipped through TDD (5 unit tests, 7 tasks, code review loops). Visual cold-launch verification then revealed:

1. `INFOPLIST_KEY_UILaunchScreen_Image` / `_BackgroundColor` in Xcode 26 are recognized as build settings but produce an empty `UILaunchScreen` dict in the compiled plist. Fix: declare the dict explicitly via `Info-Partial.plist`.
2. With the launch-screen wiring fixed, iOS rendered the 1024 px `SplashLogo` at near-full-screen size, producing a visible "huge icon → 200 pt icon" jump at handoff.

Chris redirected: "no animation, just a clean static launch screen." Reverted all SwiftUI splash machinery (`SplashSleeper`, `SplashState`, `SplashView`, `RootView` + tests), switched to a hand-written storyboard. First attempt used a near-black gradient + the full app-icon artwork as a centered tile — looked awful (gradient read as black; the baked swimlane columns floated as noise around the phoenix with no visual container). Final attempt is the solid-bg + rounded-tile shape above.

## Side-fixes shipped during the session

These were latent problems that surfaced because `make generate` was running so often:

- **`fix(xcode): stop regen from re-bundling .claude + AppIcon.icns`** (`37db09e`) — each regen was re-adding `FenixKanban/.claude/settings.local.json` and `FenixKanban/Resources/AppIcon.icns` to the Resources build phase, undoing the earlier `9432cfc` fix. Added `**/.claude/**` and `Resources/AppIcon.icns` to source-glob excludes.
- **`build(xcode): adopt Xcode 26 recommended project settings`** (`4292475`) — `STRING_CATALOG_GENERATE_SYMBOLS`, `ENABLE_USER_SCRIPT_SANDBOXING`, `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` now live in `project.yml`. Xcode's "Recommended Settings" validation dialog should not nag again.

## Test + build status

- iOS: 219/219 tests pass (clean build)
- macOS: clean build (no test target on macOS in this project's standard flow)
- TDD log: `TDD_IMPLEMENTATION_STATUS.md` section 13 added with the full retro

## Commits to push

24 commits ahead of `origin/develop` at write time. From oldest (`9e97168` design spec) to newest (`2130503` final launch-screen rework). Run `git log origin/develop..HEAD --oneline` for the full list.

## Outstanding work (unchanged from the Fizzy handoff)

The Fizzy Phase 5 UAT is still paused at items 4–7 with `BUG-push-duplicates` to investigate. See `.planning/HANDOFF.md` for the resume checklist. This splash session did not touch any Fizzy code.

## Resume checklist (splash side)

Nothing to resume. The splash is done. Future tweaks (if Chris wants them) would be:

- Pick a brand-tinted background instead of `#F2F2F7` / `#1C1C1E`
- Adjust corner radius (currently 45 pt on a 200 pt icon; Apple's home-screen mask is ~22.37% of side ≈ 45 pt — tighter or looser is a taste call)
- Add a wordmark below the icon (would require a separate image asset)

None of these are blockers.
