# Splash Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the iOS animated splash screen designed in [docs/superpowers/specs/2026-05-27-splash-screen-design.md](../specs/2026-05-27-splash-screen-design.md): a SwiftUI `SplashView` that pixel-aligns to the system launch screen, pulses, then crossfades into `ContentView`. macOS unaffected.

**Architecture:** Three small SwiftUI files (`SplashState`, `SplashView`, `RootView`) under `FenixKanban/Features/Splash/`. `SplashState` is `@Observable` + `@MainActor` and drives its timeline through an injected `SplashSleeper` so unit tests use a recording fake instead of real `Task.sleep`. `RootView` wraps `ContentView`; on iOS it overlays `SplashView` until the timeline finishes, on macOS it returns `ContentView` directly via `#if os(iOS)`. Static launch screen is configured via `INFOPLIST_KEY_UILaunchScreen_*` keys in [project.yml](../../../project.yml) — no storyboard file.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing (`@Test`/`@Suite`/`#expect`), iOS 26 / macOS 26 SDKs, XcodeGen, Make.

---

## Plan Decisions (locked here, deferred from spec)

These were "Open Questions" in the spec — locked now so the plan is unambiguous:

1. **TestClock dependency:** Hand-rolled. We introduce a tiny `SplashSleeper` protocol; tests use a `RecordingSplashSleeper` fake. Zero new dependencies.
2. **Pulse implementation:** Single-direction `.easeInOut` from scale 1.0 → 1.05 over `pulseDuration`. Settles by reaching `.fading` (which animates scale back to 1.0 alongside the opacity fade). Simpler than a two-step `withAnimation` chain and indistinguishable to the eye at 450ms.
3. **Reduce Motion fallback:** When `\.accessibilityReduceMotion` is true, `SplashView` skips the scale animation entirely (`scaleEffect(1.0)` always). The timeline is unchanged — fade still plays. No pulse, just a calm fade-out.
4. **macOS `RootView`:** Compile-time bypass — the whole `ZStack` is iOS-only; on macOS the body returns `ContentView(navigator: navigator)` directly. `SplashState` is never constructed on macOS.

## File Structure

| File | Responsibility | Created by task |
|---|---|---|
| `FenixKanban/Features/Splash/SplashSleeper.swift` | `protocol SplashSleeper` + `TaskSleeper` (prod) impl | Task 2 |
| `FenixKanban/Features/Splash/SplashState.swift` | `@Observable` timeline state machine | Task 2 |
| `FenixKanban/Features/Splash/SplashView.swift` | SwiftUI splash overlay (image + bg + animations) | Task 4 |
| `FenixKanban/Features/Splash/RootView.swift` | Wraps `ContentView`; iOS overlay; macOS pass-through | Task 5 |
| `FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/` | Splash logo asset (references `Icon-1024.png`) | Task 3 |
| `FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset/` | sRGB `#15161D` color asset | Task 3 |
| `FenixKanban/FenixKanbanApp.swift` (modify L63-L78) | Swap `ContentView` → `RootView` in `WindowGroup` | Task 6 |
| `project.yml` (modify L37-L54) | Add `INFOPLIST_KEY_UILaunchScreen_*` keys | Task 7 |
| `FenixKanbanTests/Features/Splash/SplashStateTests.swift` | Swift Testing suite for state machine | Task 1 |
| `TDD_IMPLEMENTATION_STATUS.md` (append) | Log this work per project convention | Task 9 |

---

## Task 1: Failing tests for `SplashState`

**Files:**
- Create: `FenixKanbanTests/Features/Splash/SplashStateTests.swift`

- [ ] **Step 1.1: Create the test directory**

```bash
mkdir -p "FenixKanbanTests/Features/Splash"
```

- [ ] **Step 1.2: Write the failing test file**

Create `FenixKanbanTests/Features/Splash/SplashStateTests.swift`:

```swift
import Testing
import Foundation
@testable import FenixKanban

/// Recording fake — captures every sleep duration so tests can assert
/// the timeline executed without burning real wall-clock time.
final class RecordingSplashSleeper: SplashSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Duration] = []

    var sleeps: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return _sleeps
    }

    func sleep(for duration: Duration) async throws {
        lock.lock()
        _sleeps.append(duration)
        lock.unlock()
        await Task.yield()
    }
}

@Suite("SplashState")
@MainActor
struct SplashStateTests {
    @Test("Initial phase is .pulsing")
    func initialPhase() {
        let state = SplashState()
        #expect(state.phase == .pulsing)
    }

    @Test("start() drives phase to .done")
    func endsAtDone() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        #expect(state.phase == .done)
    }

    @Test("start() sleeps for pulseDuration then fadeDuration")
    func timelineDurations() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        #expect(sleeper.sleeps == [SplashState.pulseDuration, SplashState.fadeDuration])
    }

    @Test("totalDuration equals pulse + fade")
    func durationsAddUp() {
        #expect(SplashState.totalDuration == SplashState.pulseDuration + SplashState.fadeDuration)
    }

    @Test("start() is idempotent — second call is a no-op")
    func idempotent() async {
        let state = SplashState()
        let sleeper = RecordingSplashSleeper()
        await state.start(sleeper: sleeper)
        await state.start(sleeper: sleeper)
        #expect(sleeper.sleeps.count == 2)  // not 4
        #expect(state.phase == .done)
    }
}
```

- [ ] **Step 1.3: Register the new test file with XcodeGen**

The `FenixKanbanTests` target in `project.yml` already declares `sources: - path: FenixKanbanTests`, so XcodeGen will pick up the new file automatically. Regenerate the project:

```bash
make generate
```

Expected: `xcodegen generate` exits 0; `FenixKanban.xcodeproj` updated.

- [ ] **Step 1.4: Run the tests to confirm they fail to compile**

```bash
make test
```

Expected: BUILD FAILED with errors like `cannot find type 'SplashSleeper' in scope` and `cannot find 'SplashState' in scope`. This is the RED phase — the tests reference types that don't exist yet.

- [ ] **Step 1.5: Commit the failing tests**

```bash
git add FenixKanbanTests/Features/Splash/SplashStateTests.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
test(splash): add failing SplashState timeline tests

RED phase. Covers initial state, completion, sleep durations, totalDuration
invariant, and idempotency. Uses RecordingSplashSleeper fake so tests run
without real wall-clock waits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `SplashSleeper` + `SplashState`

**Files:**
- Create: `FenixKanban/Features/Splash/SplashSleeper.swift`
- Create: `FenixKanban/Features/Splash/SplashState.swift`

- [ ] **Step 2.1: Create the Splash feature directory**

```bash
mkdir -p "FenixKanban/Features/Splash"
```

- [ ] **Step 2.2: Write `SplashSleeper.swift`**

Create `FenixKanban/Features/Splash/SplashSleeper.swift`:

```swift
import Foundation

protocol SplashSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskSleeper: SplashSleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
```

- [ ] **Step 2.3: Write `SplashState.swift`**

Create `FenixKanban/Features/Splash/SplashState.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class SplashState {
    enum Phase: Equatable { case pulsing, fading, done }

    static let pulseDuration: Duration = .milliseconds(450)
    static let fadeDuration: Duration = .milliseconds(650)
    static let totalDuration: Duration = .milliseconds(1100)

    private(set) var phase: Phase = .pulsing
    private var hasStarted = false

    func start(sleeper: SplashSleeper = TaskSleeper()) async {
        guard !hasStarted else { return }
        hasStarted = true

        try? await sleeper.sleep(for: Self.pulseDuration)
        phase = .fading
        try? await sleeper.sleep(for: Self.fadeDuration)
        phase = .done
    }
}
```

- [ ] **Step 2.4: Regenerate the project to include the new sources**

```bash
make generate
```

Expected: `xcodegen generate` exits 0.

- [ ] **Step 2.5: Run the tests to confirm GREEN**

```bash
make test
```

Expected: All 5 `SplashStateTests` pass. Pre-existing test count + 5 (so 219 → 224 on iOS).

- [ ] **Step 2.6: Commit the implementation**

```bash
git add FenixKanban/Features/Splash/SplashSleeper.swift FenixKanban/Features/Splash/SplashState.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
feat(splash): SplashState timeline state machine

GREEN phase. SplashState is @Observable + @MainActor; start() drives
.pulsing → .fading → .done via an injected SplashSleeper. Production uses
TaskSleeper (Task.sleep); tests inject a RecordingSplashSleeper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `SplashLogo` image set + `SplashBackground` color set

**Files:**
- Create: `FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/Contents.json`
- Create: `FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/Icon-1024.png` (copy of `AppIcon.appiconset/Icon-1024.png`)
- Create: `FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset/Contents.json`

- [ ] **Step 3.1: Create the asset directories**

```bash
mkdir -p "FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset"
mkdir -p "FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset"
```

- [ ] **Step 3.2: Copy the icon PNG into the splash image set**

We copy (don't symlink) so the splash asset is independent of `AppIcon`. Future icon redesigns won't auto-mutate the splash.

```bash
cp "FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png" \
   "FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/Icon-1024.png"
```

- [ ] **Step 3.3: Write `SplashLogo.imageset/Contents.json`**

Universal idiom, single-scale (we render at 200pt from a 1024px source — 5x downsample, plenty of headroom):

```json
{
  "images" : [
    {
      "filename" : "Icon-1024.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : false
  }
}
```

- [ ] **Step 3.4: Write `SplashBackground.colorset/Contents.json`**

sRGB `#15161D` = (21, 22, 29) / 255 = (0.082, 0.086, 0.114). Single appearance — same value light + dark for visual continuity with the launch screen:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.114",
          "green" : "0.086",
          "red" : "0.082"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3.5: Regenerate + build to confirm assets are valid**

```bash
make generate && make build
```

Expected: Build succeeds. Asset catalog compilation prints no warnings about `SplashLogo` or `SplashBackground`.

- [ ] **Step 3.6: Commit the assets**

```bash
git add FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset \
        FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset
git commit -m "$(cat <<'EOF'
assets(splash): SplashLogo image set + SplashBackground color set

SplashLogo references a copy of Icon-1024.png so the splash is decoupled
from AppIcon. SplashBackground is sRGB #15161D — matches the icon's baked
background for an invisible handoff from the system launch screen.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Build `SplashView`

**Files:**
- Create: `FenixKanban/Features/Splash/SplashView.swift`

- [ ] **Step 4.1: Write `SplashView.swift`**

Create `FenixKanban/Features/Splash/SplashView.swift`:

```swift
import SwiftUI

struct SplashView: View {
    let phase: SplashState.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color("SplashBackground")
                .ignoresSafeArea()
            Image("SplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.45), value: phase)
        }
        .opacity(phase == .fading || phase == .done ? 0 : 1)
        .animation(.easeOut(duration: 0.65), value: phase)
    }

    private var scale: CGFloat {
        if reduceMotion { return 1.0 }
        switch phase {
        case .pulsing: return 1.05
        case .fading, .done: return 1.0
        }
    }
}

#Preview("Pulsing") { SplashView(phase: .pulsing) }
#Preview("Fading")  { SplashView(phase: .fading)  }
```

- [ ] **Step 4.2: Regenerate + build**

```bash
make generate && make build
```

Expected: Build succeeds, no warnings.

- [ ] **Step 4.3: Commit `SplashView`**

```bash
git add FenixKanban/Features/Splash/SplashView.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
feat(splash): SplashView — pulse + crossfade overlay

Full-bleed SplashBackground + 200pt centered SplashLogo. Scale animates
to 1.05 during .pulsing then back to 1.0 during .fading; opacity fades
on .fading. Reduce Motion suppresses the scale animation but keeps the
fade for a calm transition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build `RootView`

**Files:**
- Create: `FenixKanban/Features/Splash/RootView.swift`

- [ ] **Step 5.1: Write `RootView.swift`**

Create `FenixKanban/Features/Splash/RootView.swift`. The macOS branch is a compile-time bypass — no splash construction at all on Mac:

```swift
import SwiftUI

struct RootView: View {
    @Bindable var navigator: NavigationModel

    #if os(iOS)
    @State private var splashState = SplashState()
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            ContentView(navigator: navigator)
                .opacity(splashState.phase == .done ? 1 : 0)
                .animation(.easeIn(duration: 0.65), value: splashState.phase)

            if splashState.phase != .done {
                SplashView(phase: splashState.phase)
                    .task { await splashState.start() }
            }
        }
        #else
        ContentView(navigator: navigator)
        #endif
    }
}
```

- [ ] **Step 5.2: Regenerate + build for iOS sim**

```bash
make generate && make build
```

Expected: Build succeeds. (At this point `RootView` is defined but unused — no warning because Swift doesn't flag unreferenced top-level types in app targets.)

- [ ] **Step 5.3: Build for macOS to confirm the platform guard compiles**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' build | xcbeautify 2>/dev/null || \
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' build
```

Expected: macOS build succeeds. The `#if os(iOS)` block compiles out cleanly.

- [ ] **Step 5.4: Commit `RootView`**

```bash
git add FenixKanban/Features/Splash/RootView.swift FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
feat(splash): RootView wraps ContentView with iOS splash overlay

On iOS, RootView overlays SplashView until SplashState.phase == .done,
then crossfades. On macOS, the whole splash path is compiled out and
RootView returns ContentView directly — no SplashState constructed,
no Mac launch animation (Dock bounce remains the platform splash).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `RootView` into `FenixKanbanApp`

**Files:**
- Modify: `FenixKanban/FenixKanbanApp.swift` (L62-L80, the `body` of `FenixKanbanApp`)

- [ ] **Step 6.1: Read the current `body` so the Edit will match exactly**

Read [FenixKanban/FenixKanbanApp.swift:62-80](../../../FenixKanban/FenixKanbanApp.swift#L62-L80) to confirm the surrounding lines haven't drifted.

- [ ] **Step 6.2: Swap `ContentView` → `RootView` in `WindowGroup`**

Replace the single occurrence:

```swift
// Before
        WindowGroup {
            ContentView(navigator: navigator)
                .environment(\.managedObjectContext, persistence.viewContext)
```

```swift
// After
        WindowGroup {
            RootView(navigator: navigator)
                .environment(\.managedObjectContext, persistence.viewContext)
```

Only the `ContentView(navigator: navigator)` line changes. All `.environment(...)`, `.environmentObject(...)`, `.preferredColorScheme(...)`, `.onReceive(...)`, and `.task { ... }` modifiers remain attached to `RootView` — they apply to whatever it wraps. `ContentView` itself is unchanged (still defined in the same file, just referenced via `RootView`).

- [ ] **Step 6.3: Build for iOS sim**

```bash
make build
```

Expected: Build succeeds.

- [ ] **Step 6.4: Run the full test suite — no regressions**

```bash
make test
```

Expected: All tests pass (224 on iOS — the original 219 plus the 5 new `SplashStateTests`).

- [ ] **Step 6.5: Commit the wiring**

```bash
git add FenixKanban/FenixKanbanApp.swift
git commit -m "$(cat <<'EOF'
feat(splash): wire RootView into FenixKanbanApp WindowGroup

Replaces ContentView with RootView as the WindowGroup root. All scene
modifiers (environment, environmentObject, preferredColorScheme, onReceive,
.task for StoreKit transactions) remain attached and apply transitively
to ContentView through RootView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Configure the system launch screen via `project.yml`

**Files:**
- Modify: `project.yml` (L37-L54, `targets.FenixKanban.settings.base`)

- [ ] **Step 7.1: Add the launch-screen keys to `settings.base`**

The existing block (around line 38) already sets `INFOPLIST_KEY_UILaunchScreen_Generation: YES`. Append the two new keys directly below it. Locate this block:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.bluefenixproductions.FenixKanban
        INFOPLIST_FILE: FenixKanban/Resources/Info-Partial.plist
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
```

And update it to:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.bluefenixproductions.FenixKanban
        INFOPLIST_FILE: FenixKanban/Resources/Info-Partial.plist
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_BackgroundColor: SplashBackground
        INFOPLIST_KEY_UILaunchScreen_Image: SplashLogo
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
```

(Only two lines inserted, between `_Generation: YES` and `UIApplicationSceneManifest_Generation: YES`.)

- [ ] **Step 7.2: Regenerate the Xcode project**

```bash
make generate
```

Expected: `xcodegen generate` exits 0.

- [ ] **Step 7.3: Build and confirm the generated `Info.plist` includes the launch-screen dict**

```bash
make build
# Then inspect the built app's Info.plist:
find "$HOME/Library/Developer/Xcode/DerivedData" -name "FenixKanban-*" -type d -print -quit \
  | xargs -I {} find {} -path "*/Debug-iphonesimulator/FenixKanban.app/Info.plist" -print -quit \
  | xargs -I {} /usr/libexec/PlistBuddy -c "Print :UILaunchScreen" {}
```

Expected output contains:
```
Dict {
    UIImageName = SplashLogo
    UIColorName = SplashBackground
}
```

If the path discovery fails, open the built app in Finder (DerivedData → FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app → right-click → Show Package Contents → Info.plist) and verify the same dict by eye.

- [ ] **Step 7.4: Commit the project.yml change**

```bash
git add project.yml FenixKanban.xcodeproj
git commit -m "$(cat <<'EOF'
build(splash): point system launch screen at SplashLogo on SplashBackground

Adds INFOPLIST_KEY_UILaunchScreen_Image and _BackgroundColor so Xcode's
auto-generated UILaunchScreen dict renders the splash assets statically
before the app process boots. macOS ignores UILaunchScreen* keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Manual verification — the illusion holds

This task is not unit-testable. Per [CLAUDE.md](../../../CLAUDE.md) "test the UI in the app, not just in tests," we cold-launch on each target.

- [ ] **Step 8.1: Cold-launch on iPhone simulator**

```bash
# Erase the simulator first to force a true cold launch:
xcrun simctl erase "iPhone 17" 2>/dev/null || true
xcrun simctl boot "iPhone 17" 2>/dev/null || true
open -a Simulator
# Install + launch:
xcrun simctl install booted "$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/Debug-iphonesimulator/FenixKanban.app" -type d -print -quit)"
xcrun simctl launch booted com.bluefenixproductions.FenixKanban
```

**Verify by eye:**
- [ ] Launch screen → SplashView handoff is invisible (no jump in icon size, position, or background color)
- [ ] Pulse is perceptible but gentle (logo grows ~5% then settles)
- [ ] Crossfade to ContentView is smooth, no flicker
- [ ] Total splash duration feels ~1 second (not too long, not jumpy)
- [ ] AuthView or BoardListView appears after the splash, depending on `hasSkippedAuth`

- [ ] **Step 8.2: Cold-launch on iPad simulator**

```bash
xcrun simctl shutdown all 2>/dev/null || true
# Launch an iPad sim — e.g. iPad Pro 13-inch
xcrun simctl boot "iPad Pro 13-inch (M4)" 2>/dev/null || \
  xcrun simctl boot "iPad Pro (13-inch) (M4)" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted "$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/Debug-iphonesimulator/FenixKanban.app" -type d -print -quit)"
xcrun simctl launch booted com.bluefenixproductions.FenixKanban
```

Verify the same checks as Step 8.1 in landscape and portrait. The 200pt logo should remain centered after rotation.

- [ ] **Step 8.3: Cold-launch on macOS to confirm no splash**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' build
# Find and launch the built Mac app:
open "$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/Debug/FenixKanban.app" -type d -print -quit)"
```

Verify:
- [ ] App opens directly to ContentView (AuthView or BoardListView). No dark-navy splash overlay appears at any point.
- [ ] Window background renders as normal macOS chrome (no Splash artifacts).

- [ ] **Step 8.4: Test Reduce Motion on iOS**

In the iPhone sim: **Settings → Accessibility → Motion → Reduce Motion** (ON). Force-quit the app and cold-launch again.

Verify:
- [ ] Splash still appears
- [ ] Logo does NOT pulse (stays at scale 1.0)
- [ ] Fade-out still plays smoothly
- [ ] Total duration feels the same (~1 second)

Restore Reduce Motion to OFF.

- [ ] **Step 8.5: Commit a verification note (no code changes)**

If any of 8.1–8.4 failed, fix the code first, then re-verify before committing. If all passed:

```bash
git commit --allow-empty -m "$(cat <<'EOF'
chore(splash): manual verification — illusion holds

Cold-launched on iPhone 17 sim, iPad Pro sim (portrait + landscape),
macOS, and iPhone 17 with Reduce Motion. Launch-screen → SplashView
handoff is visually seamless on iOS; macOS opens directly to ContentView
with no splash artifacts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Update `TDD_IMPLEMENTATION_STATUS.md`

**Files:**
- Modify: `TDD_IMPLEMENTATION_STATUS.md` (append a new section)

Per the project memory: `TDD_IMPLEMENTATION_STATUS.md` is a living log; append after any code change.

- [ ] **Step 9.1: Append the splash section**

Add this section at the bottom of `TDD_IMPLEMENTATION_STATUS.md`:

```markdown
---

### 13. Splash Screen (iOS) ✅
**Status:** Complete (Red → Green → Refactor)
**Date:** 2026-05-27
**Spec:** `docs/superpowers/specs/2026-05-27-splash-screen-design.md`
**Plan:** `docs/superpowers/plans/2026-05-27-splash-screen.md`

**🔴 Red Phase:**
- Created `FenixKanbanTests/Features/Splash/SplashStateTests.swift` with 5 failing tests
- Tests verified to fail to compile (types not yet defined)

**🟢 Green Phase:**
- Created `FenixKanban/Features/Splash/SplashSleeper.swift` (protocol + `TaskSleeper`)
- Created `FenixKanban/Features/Splash/SplashState.swift` (`@Observable @MainActor` state machine)
- All 5 tests pass; total iOS test count 219 → 224

**🔵 Refactor Phase:**
- Added `SplashLogo` image set + `SplashBackground` color set (`#15161D`)
- Created `SplashView.swift` (pulse + fade, Reduce Motion aware)
- Created `RootView.swift` (iOS overlay, macOS pass-through)
- Wired `RootView` into `FenixKanbanApp.WindowGroup`
- Added `INFOPLIST_KEY_UILaunchScreen_Image` + `_BackgroundColor` in `project.yml`
- Cold-launch verification: iPhone sim, iPad sim, macOS, iPhone with Reduce Motion

**Files Created:**
- `FenixKanban/Features/Splash/SplashSleeper.swift`
- `FenixKanban/Features/Splash/SplashState.swift`
- `FenixKanban/Features/Splash/SplashView.swift`
- `FenixKanban/Features/Splash/RootView.swift`
- `FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/`
- `FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset/`
- `FenixKanbanTests/Features/Splash/SplashStateTests.swift`

**Files Modified:**
- `FenixKanban/FenixKanbanApp.swift` (WindowGroup root: ContentView → RootView)
- `project.yml` (added two `INFOPLIST_KEY_UILaunchScreen_*` lines)

**Test Coverage:** Timeline state machine (5 tests). View rendering verified manually per CLAUDE.md.
```

Section number is `13.` based on the existing 12 sections in the file as of 2026-05-27. If more sections have been added since the plan was written, increment accordingly — `grep -E "^### [0-9]+\\." TDD_IMPLEMENTATION_STATUS.md | wc -l` returns the current count.

- [ ] **Step 9.2: Commit the status update**

```bash
git add TDD_IMPLEMENTATION_STATUS.md
git commit -m "$(cat <<'EOF'
docs(tdd): log splash screen (iOS) work

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification — full suite, both platforms, zero warnings

- [ ] **Step 10.1: Clean build on iOS sim**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' clean build test | xcbeautify 2>/dev/null || \
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' clean build test
```

Expected: Build succeeds with **zero warnings**; all tests pass (224 expected — original 219 + 5 splash).

- [ ] **Step 10.2: Clean build on macOS**

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' clean build | xcbeautify 2>/dev/null || \
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' clean build
```

Expected: Build succeeds with zero warnings. (Tests on macOS use the same suite; if a separate `macOS test` invocation is part of project convention, run it.)

- [ ] **Step 10.3: Confirm clean git tree**

```bash
git status --short
```

Expected: Working tree clean.

- [ ] **Step 10.4: (Optional) Open a PR**

If shipping via PR rather than direct-to-develop, push the branch and open a PR pointing at the spec and plan files:

```bash
git push -u origin HEAD
gh pr create --title "feat(splash): iOS animated splash screen" --body "$(cat <<'EOF'
## Summary
- Adds iOS animated splash screen per [the design spec](docs/superpowers/specs/2026-05-27-splash-screen-design.md)
- Pixel-aligned handoff from system launch screen to SwiftUI `SplashView`, gentle pulse, crossfade to `ContentView`
- macOS unchanged (Dock bounce is the platform splash)
- 5 new Swift Testing cases for `SplashState` timeline; no real-time `sleep` in tests
- Reduce Motion suppresses the pulse but keeps the fade

## Test plan
- [ ] `make test` passes (224 expected)
- [ ] macOS build passes with no warnings
- [ ] Cold launch on iPhone sim — handoff is visually seamless
- [ ] Cold launch on iPad sim portrait + landscape
- [ ] Cold launch on macOS — no splash artifacts
- [ ] Cold launch on iPhone with Reduce Motion — fade still plays, no pulse

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Total: 10 tasks, ~36 steps, 9 commits (10 if PR push counts)

Spec → Plan → Red (Task 1) → Green (Task 2) → Refactor (Tasks 3-7) → Verify (Tasks 8, 10) → Document (Task 9).
