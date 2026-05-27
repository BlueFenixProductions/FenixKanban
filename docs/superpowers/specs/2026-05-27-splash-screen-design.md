# Splash Screen Design (iOS)

**Date:** 2026-05-27
**Status:** Approved for planning
**Reference:** [Animated iOS Splash Screens: The Illusion Apple Actually Allows](https://dev.to/voinkoder/animated-ios-splash-screens-the-illusion-apple-actually-allows-52ej)

## Summary

Add an animated splash screen on iOS that creates the illusion of continuous animation from cold launch. The static system launch screen renders the AppIcon on a dark-navy background; the SwiftUI root view immediately replaces it with a pixel-aligned `SplashView` that plays a gentle pulse, then crossfades into `ContentView`. macOS is unaffected.

## Goals

- Cold-launch UX matches the polish of native Apple apps — no perceptible jump between launch screen and first frame.
- Reuse the existing app-icon artwork; no new graphic-design work.
- Pure SwiftUI implementation; no `SceneDelegate`, no `LaunchScreen.storyboard`.
- iOS-only. macOS launches straight into `ContentView` (Dock bounce is the platform's splash).
- Testable timeline logic (Swift Testing) with no real-time `sleep` in unit tests.

## Non-Goals

- Lottie / video / particle-effect splash.
- Light-mode-specific splash palette (icon background is dark; we keep it dark on both appearances for continuity with the launch screen).
- Skipping the splash on warm/foreground returns (SwiftUI `@State` already resets only on process restart, which gives the desired behavior for free).
- A parallel macOS splash.

## The Illusion (Architecture)

1. **Static launch screen** — Xcode-generated `UILaunchScreen` dict points at `SplashLogo` image asset on `SplashBackground` color asset. Renders before app code runs.
2. **`SplashView`** — SwiftUI view with the same image, same background, same 200pt sizing, centered with the same anchors. First-frame parity is the whole trick.
3. **Animation** — gentle pulse → crossfade to `ContentView` underneath → splash removed from hierarchy.
4. **Platform guard** — `RootView` is iOS-only-overlay; macOS renders `ContentView` directly.

## Asset Additions

| Asset | Type | Path | Notes |
|---|---|---|---|
| `SplashLogo` | image set | `FenixKanban/Resources/Assets.xcassets/SplashLogo.imageset/` | References the existing `Icon-1024.png` source from `AppIcon.appiconset`. Decoupled from `AppIcon` so future icon redesigns don't auto-mutate the splash. Universal idiom, 1x/2x/3x not needed (single 1024px source, rendered at 200pt). |
| `SplashBackground` | color set | `FenixKanban/Resources/Assets.xcassets/SplashBackground.colorset/` | sRGB `#15161D` (matches the icon's baked background). Same value for Any Appearance and Dark Appearance. |

## Info.plist (via [project.yml](../../../project.yml))

Add to `targets.FenixKanban.settings.base`:

```yaml
INFOPLIST_KEY_UILaunchScreen_BackgroundColor: SplashBackground
INFOPLIST_KEY_UILaunchScreen_Image: SplashLogo
```

These feed Xcode's auto-generated `UILaunchScreen` dictionary. No storyboard required. macOS ignores `UILaunchScreen*` keys.

`INFOPLIST_KEY_UILaunchScreen_Generation: YES` is already set.

## Code Additions

Three new files under a new `FenixKanban/Features/Splash/` group:

### `SplashState.swift`

```swift
import Foundation
import Observation

@Observable
@MainActor
final class SplashState {
    enum Phase: Equatable { case pulsing, fading, done }

    private(set) var phase: Phase = .pulsing
    private var hasStarted = false

    /// Total wall-clock duration (locked at 1.1s).
    static let totalDuration: Duration = .milliseconds(1100)
    static let pulseDuration: Duration = .milliseconds(450)
    static let fadeDuration: Duration = .milliseconds(650)

    /// Drives the timeline. Idempotent — calling twice is a no-op.
    /// Clock is injected so tests use a fake instead of real time.
    func start<C: Clock>(clock: C) async where C.Duration == Duration {
        guard !hasStarted else { return }
        hasStarted = true

        try? await clock.sleep(for: Self.pulseDuration)
        phase = .fading
        try? await clock.sleep(for: Self.fadeDuration)
        phase = .done
    }
}
```

### `SplashView.swift`

```swift
import SwiftUI

struct SplashView: View {
    let phase: SplashState.Phase

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
        .opacity(phase == .fading ? 0 : 1)
        .animation(.easeOut(duration: 0.65), value: phase)
    }

    private var scale: CGFloat {
        switch phase {
        case .pulsing: 1.05  // settles back via the animation curve mid-pulse
        case .fading, .done: 1.0
        }
    }
}
```

Pulse refinement: the pulse is implemented as a single `.easeInOut` animation that transitions 1.0 → 1.05; during planning we may swap to a `withAnimation` two-step (1.0 → 1.05 → 1.0) using `Task { await ... }` inside `SplashView.onAppear` if the single-curve version feels too subtle. Final call during implementation.

### `RootView.swift`

```swift
import SwiftUI

struct RootView: View {
    @Bindable var navigator: NavigationModel
    @State private var splashState = SplashState()

    var body: some View {
        ZStack {
            ContentView(navigator: navigator)
                .opacity(splashState.phase == .done ? 1 : 0)
                .animation(.easeIn(duration: 0.65), value: splashState.phase)

            #if os(iOS)
            if splashState.phase != .done {
                SplashView(phase: splashState.phase)
                    .transition(.opacity)
                    .task {
                        await splashState.start(clock: ContinuousClock())
                    }
            }
            #endif
        }
    }
}
```

On macOS the `#if os(iOS)` branch compiles out entirely — `SplashState` is still constructed but `start` is never called, so `phase` stays `.pulsing` forever. The `ContentView.opacity` modifier is therefore wrong on macOS. **Fix in implementation:** initialize `splashState` with `phase = .done` on macOS via a platform-conditional initializer, or short-circuit `RootView` to `ContentView(navigator: navigator)` directly on macOS. Plan will pick one.

### `FenixKanbanApp.swift` change

```swift
// Before
WindowGroup {
    ContentView(navigator: navigator)
        .environment(\.managedObjectContext, persistence.viewContext)
        // ... modifiers
}

// After
WindowGroup {
    RootView(navigator: navigator)
        .environment(\.managedObjectContext, persistence.viewContext)
        // ... same modifiers
}
```

## Animation Timeline

| t (s) | State | Visible |
|---|---|---|
| 0.00 | Process alive, first SwiftUI frame | `SplashView` — pixel-identical to system launch screen. Invisible handoff. |
| 0.00–0.45 | `.pulsing` | Logo eases from 1.0 → 1.05. |
| 0.45 | → `.fading` | Pulse settles; crossfade begins. |
| 0.45–1.10 | `.fading` | `ContentView` opacity 0 → 1 underneath. `SplashView` opacity 1 → 0 over it. |
| 1.10 | → `.done` | Splash removed from view hierarchy. App is interactive. |

Total: **1.1 seconds** from first frame to interactive.

## TDD Plan

### Red phase — `FenixKanbanTests/Features/Splash/SplashStateTests.swift`

Swift Testing suite covering the timeline logic. No view rendering.

```swift
import Testing
import Foundation
@testable import FenixKanban

@Suite("SplashState")
@MainActor
struct SplashStateTests {
    @Test("Starts in pulsing phase")
    func initialPhase() {
        let state = SplashState()
        #expect(state.phase == .pulsing)
    }

    @Test("Transitions pulsing → fading → done on the timeline")
    func timelineTransitions() async {
        let clock = TestClock()  // swift-clocks or hand-rolled fake
        let state = SplashState()

        async let run: () = state.start(clock: clock)
        // Advance through pulse
        await clock.advance(by: SplashState.pulseDuration)
        await Task.yield()
        #expect(state.phase == .fading)

        // Advance through fade
        await clock.advance(by: SplashState.fadeDuration)
        await Task.yield()
        #expect(state.phase == .done)

        await run
    }

    @Test("start() is idempotent")
    func idempotent() async {
        let clock = TestClock()
        let state = SplashState()

        async let run1: () = state.start(clock: clock)
        await Task.yield()
        async let run2: () = state.start(clock: clock)

        await clock.advance(by: SplashState.totalDuration)
        await run1
        await run2

        #expect(state.phase == .done)
        // No assertion on time — second start is a no-op, doesn't extend timeline.
    }

    @Test("totalDuration equals pulse + fade")
    func durationsAddUp() {
        #expect(SplashState.totalDuration == SplashState.pulseDuration + SplashState.fadeDuration)
    }
}
```

**TestClock source:** prefer a tiny hand-rolled fake to avoid a new dependency. Implementation plan decides — if the codebase already has a clock fake we use that.

### Green phase
Implement `SplashState` to pass all four tests. No view code yet.

### Refactor phase
Add `SplashView`, `RootView`, wire `FenixKanbanApp`, add assets + plist keys, regenerate Xcode project (`make generate` or `xcodegen`), run on iOS simulator to verify the visual handoff.

### Manual verification (not unit-testable)
- Cold launch on iOS simulator (iPhone 16, iPad Pro) and a physical iPhone: launch-screen-to-splash handoff is invisible (no jump in icon position, scale, or background color).
- Cold launch on macOS: `ContentView` appears immediately, no splash overlay.
- Dark and light system appearance both render the dark splash without flicker.
- Reduce Motion: the pulse should fall back to a static hold + fade. Plan will add `@Environment(\.accessibilityReduceMotion)` gate.

## Definition of Done

Per [CLAUDE.md](../../../CLAUDE.md):

- All `SplashStateTests` pass.
- Existing test suite (iOS 219/219 + macOS) still green.
- Build succeeds for both iOS and macOS targets with zero warnings.
- Manual cold-launch verification on iOS sim confirms the illusion holds.
- `TDD_IMPLEMENTATION_STATUS.md` updated with this work.

## Open Questions for the Implementation Plan

1. **TestClock dependency** — hand-roll a fake or pull in a tiny library? Hand-rolled wins on zero-dependency grounds; library wins if the codebase grows more time-based logic.
2. **Pulse implementation** — single-direction `.easeInOut` (settles via curve) vs. explicit two-step `withAnimation` (1.0 → 1.05 → 1.0). Both fit the timeline; settle in implementation by feel.
3. **Reduce Motion fallback** — confirmed in scope (hold + fade only), but the exact timing (skip the 0.45s pulse window, or hold for the full 1.1s) is a plan decision.
4. **macOS path in `RootView`** — initializer that sets `.done` on macOS, or compile-time bypass to `ContentView` directly. Plan picks the cleaner option.
