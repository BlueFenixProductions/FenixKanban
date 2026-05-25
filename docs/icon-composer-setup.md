# App Icon — Icon Composer Setup

For iOS 26 / macOS 26 / iPadOS 26, app icons should be built in **Icon Composer** with layered, semi-transparent shapes — the system applies shadows, blurs, and refraction at render time. Pre-baking those effects produces icons that look static and wrong next to Liquid Glass system chrome.

This is a **design task** that requires the Icon Composer GUI (bundled with Xcode 16+); it can't be scripted from the command line. This document is the step-by-step setup so the work can happen in one sitting.

## Current state

- `FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/` contains the existing raster icon (`Icon-1024.png` for both iOS and macOS, plus the macOS sizes `Icon-16.png` through `Icon-512.png`). These are the legacy assets.
- They render fine, but they're static — they don't get the iOS 26 dynamic appearance variants (light / dark / clear / tinted) and they don't refract under Liquid Glass.

## Target state

A single `.icon` document (Icon Composer's native format) checked into `FenixKanban/Resources/AppIcon.icon/` that:

1. Renders correctly on iOS, iPadOS, and macOS via the rounded-rectangle mask (and watchOS via the circular mask, if/when watchOS support is added).
2. Provides **light**, **dark**, **clear**, and **tinted** variants — users select these in iOS Settings → Home Screen.
3. Uses layered, semi-transparent shapes so the system can apply shadows / blurs / refraction dynamically.

## Step-by-step

### 1. Open Icon Composer

```bash
open -a "Icon Composer"
```

If that fails, Icon Composer ships inside Xcode:

```bash
open "$(xcode-select -p)/Applications/Icon Composer.app"
```

Apple's intro guide: [Adopting Liquid Glass — App Icons](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass#App-icons).

### 2. Start a new icon document

- File → New → choose a single-platform-but-shared template (the wizard offers iOS, macOS, watchOS, etc.; pick "Multiplatform" if available).
- Save to `FenixKanban/Resources/AppIcon.icon` (this becomes a bundle/folder).

### 3. Build the icon with layered shapes

Use the existing `Icon-1024.png` as a reference image (drop it onto the canvas as a guide), then **rebuild the icon as separate layers**, not as a flattened image:

- **Background layer:** the brand color or gradient. **Do not** include the rounded-corner mask — the system applies that.
- **Phoenix / fire silhouette layer(s):** semi-transparent shapes that the system will shadow.
- **Kanban grid layer(s):** if the existing design uses one.
- Each layer should be a single solid color (or gradient) with an alpha channel for shape — **no baked drop shadows, no baked blurs, no baked refractive highlights.**
- Keep the design **centered** within the canvas — irregular shapes get a system-supplied background, and iOS / iPadOS / macOS apply a rounded-rectangle mask (watchOS is circular). Off-centre art gets clipped.

### 4. Configure the four appearance variants

In Icon Composer's Variants pane:

- **Light:** the default, full-color version.
- **Dark:** a version tuned for the dark Home Screen appearance — usually a deeper / desaturated background with the same foreground silhouette.
- **Clear:** a translucent version — the foreground silhouette over a clear/blurred system background.
- **Tinted:** a monochrome version that the system re-tints based on the user's wallpaper colors.

### 5. Wire it up in the project

Replace the legacy raster asset references:

- In `project.yml`, the `resources:` list for the `FenixKanban` target currently doesn't reference the icon directly (it's pulled in via `Assets.xcassets`). After saving the new `.icon` document:
  1. Delete `FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/`.
  2. Confirm the new `FenixKanban/Resources/AppIcon.icon/` is picked up by xcodegen — it should be, since `path: FenixKanban/Resources/Assets.xcassets` is included as a resource, **and** sibling assets in `FenixKanban/Resources/` will be auto-included by xcodegen's wildcard scan. If it isn't, add an explicit `- path: FenixKanban/Resources/AppIcon.icon` entry to the `resources:` list.
  3. Run `xcodegen generate` and confirm `grep -E "AppIcon\.icon|AppIcon\.appiconset" FenixKanban.xcodeproj/project.pbxproj` shows only the new `.icon` reference.

### 6. Verify on iOS Simulator

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install "iPhone 17" \
  "$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug-iphonesimulator/FenixKanban.app | head -1)"
# Open the simulator, long-press Home Screen → Edit → confirm icon renders correctly
# in Light / Dark / Clear / Tinted appearances.
```

### 7. Verify on macOS

```bash
xcodebuild -project FenixKanban.xcodeproj -scheme FenixKanban \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
open "$(ls -td ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products/Debug/FenixKanban.app | head -1)"
# Confirm icon appears in Dock and in Cmd-Tab with the correct dynamic appearance.
```

### 8. Commit

```bash
git add FenixKanban/Resources/AppIcon.icon FenixKanban/Resources/Assets.xcassets project.yml FenixKanban.xcodeproj/project.pbxproj
git rm -r FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset
git commit -m "feat: rebuild app icon in Icon Composer for Liquid Glass"
```

Update `TDD_IMPLEMENTATION_STATUS.md` per the repo rule.

## Why this can't be automated

Icon Composer is a SwiftUI/AppKit GUI tool — it has no documented CLI or scripting API as of Xcode 16. The `.icon` document format is a structured bundle that's authored visually. Once authored, it's just a file on disk and behaves like any other resource.
