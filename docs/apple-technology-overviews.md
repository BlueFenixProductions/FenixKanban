# Apple Technology Overviews — Adoption Reference for iOS 26 / macOS 26

> **2026-06-12 update:** the Liquid Glass section now carries an iOS 27 / macOS 27 (WWDC 2026)
> delta subsection, fetched live from Apple docs + beta release notes. Deployment floor for this
> repo remains **iOS 26 / macOS 26**; any 27-only API must be gated `#available(iOS 27, *)`.

_Compiled: 2026-05-25_

This is a synthesized, action-oriented reference distilled from Apple's official
[Technology Overviews](https://developer.apple.com/documentation/technologyoverviews) index and
the linked guides. It targets a SwiftUI/UIKit/AppKit developer building for iOS 26 and macOS 26
(plus iPadOS 26, tvOS 26, watchOS 26, visionOS 26). Every section is sourced from a specific Apple
overview page — click the link in the section header to read the original.

The first major section, **Liquid Glass**, is the marquee adoption story for this OS generation
and is the longest. Subsequent sections summarize the remaining overview pages with terse,
actionable rules. The final section is a compressed quick-reference checklist.

---

## Liquid Glass

Source: [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
· Hub: [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)

Liquid Glass is the new system-wide dynamic material introduced this OS generation. It combines
the optical properties of glass with a sense of fluidity, forming a **distinct functional layer**
for controls and navigation that sits above content. It adapts in response to element overlap,
focus state, motion, and accessibility settings, with the explicit purpose of bringing focus to
the underlying content.

### How to opt in (and what comes for free)

- **Rebuild against the latest SDKs in the latest Xcode.** Standard SwiftUI / UIKit / AppKit
  components — bars, sheets, popovers, controls, tab bars, sidebars, toolbars — pick up Liquid
  Glass automatically across iOS, iPadOS, macOS, tvOS, and watchOS.
- **Do nothing else, in most cases.** Standard components also dynamically adapt to element
  overlap and focus state without code. This is the single biggest leverage point: use stock
  controls.
- **Test the rebuild visually before customizing anything.** The visual refresh covers control
  shapes, sizes, corner radii, sheet inset, capitalization conventions in section headers, list/
  table/form row heights, and more.

### How to opt out (escape hatch for shipping)

- Add the [`UIDesignRequiresCompatibility`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIDesignRequiresCompatibility)
  key to your `Info.plist` to ship against the latest SDKs while keeping the previous appearance.
- Use sparingly; it's a transitional safety net, not a long-term strategy. Plan to remove it.

### The four overarching rules

1. **Lean on system frameworks.** Liquid Glass auto-adopts for standard components — don't fight
   it with custom backgrounds.
2. **Reduce custom backgrounds in controls, bars, and navigation.** Custom backgrounds on split
   views, tab bars, toolbars, sheets, and popovers overlay or interfere with Liquid Glass and the
   system's scroll edge effect. Remove them; let the system render.
3. **Test under accessibility & display settings.** Users can change their preferred Liquid Glass
   look, reduce transparency, or reduce motion. Standard components adapt automatically. Custom
   elements, colors, and animations must be re-verified under each combination.
4. **Do not overuse the material.** Liquid Glass is for the most important functional elements
   only — overusing it on custom controls distracts from content. See
   [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views).

### App icons (mandatory work)

- App icons are now **layered, dynamic, and expressive**, with default (light), dark, clear, and
  tinted variants on iOS, iPadOS, and macOS.
- **Redesign for Liquid Glass.** Use solid, filled, overlapping semi-transparent shapes; keep
  designs simple and optically balanced across platforms.
- **Don't pre-bake effects.** Let the system apply reflection, refraction, shadow, blur, and
  highlights to your layers.
- **Use Icon Composer** (in latest Xcode, also via Apple Design Resources) to assemble layers,
  group them, adjust opacity, and preview against the new grids. See
  [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer).
- **Updated grids:** rounded-rectangle on iOS/iPadOS/macOS; circular on watchOS. Keep elements
  centered to avoid clipping. Irregular icons get a system-provided background.

### Controls

- Controls get **rounder, larger forms** (slider/toggle knobs morph into Liquid Glass during
  interaction; buttons morph into menus/popovers). An extra-large size option exists.
- **Stop hard-coding layout metrics.** Standard controls pick up new shapes/sizes automatically
  if you don't override them.
- **Be judicious with color.** Use system colors or a custom color with light/dark variants
  plus an increased-contrast option in each.
- **Avoid crowding/overlapping.** Use standard spacing metrics; don't layer Liquid Glass
  elements on each other.
- **Custom bars with scrolling content beneath them** must register a scroll edge effect via
  [`scrollEdgeEffectStyle(_:for:)`](https://developer.apple.com/documentation/SwiftUI/View/scrollEdgeEffectStyle(_:for:)).
  System bars (toolbar etc.) already do this.
- **Concentric corner radii.** Align shape of controls with their containers — hardware
  curvature informs nested element curvature.
- **Use new system button styles** instead of building custom Liquid Glass buttons. Always
  prefer a built-in `ButtonStyle` over hand-rolling glass effects.

### Navigation

- Liquid Glass applies to the **topmost layer** — where your navigation lives. Tab bars and
  sidebars float in this glass layer above content.
- **Establish a clear navigation hierarchy** that's visually distinct from content.
- **Adopt automatic tab-bar ↔ sidebar adaptation** so your iPadOS app reflows correctly based
  on context (use the new tab/sidebar APIs together).
- **Split views are first-class for sidebar + inspector layouts.** Use standard split view APIs
  rather than building custom column layouts.
- **Audit safe areas around sidebars and inspectors** so content underneath peeks through
  correctly.
- **Background extension effect** mirrors content under a sidebar/inspector for an edge-to-edge
  feel — great for hero images on product pages in split-view apps.
- **iOS auto-minimizing tab bars:** opt into having the tab bar recede on scroll (configurable
  to minimize on scroll-up or scroll-down). The bar expands on reverse scroll.

### Menus and toolbars

- Menus get a refresh and now use icons for common actions. **iPadOS apps now have a menu bar.**
- **Use standard selectors for standard actions** (Cut/Copy/Paste/etc.); the system applies
  icons automatically from the selector.
- **Match top-of-context-menu actions to swipe actions** for the same item — for consistency.
- **Group toolbar items** that share an action target. Use fixed spacers to separate items that
  share a background.
- **Prefer icons over text in toolbars** — but never mix text and icons in items that share a
  background.
- **Always set an accessibility label on every icon** (VoiceOver / Voice Control).
- **Hide toolbar items, not their content.** If you see an empty slot, you're probably hiding
  the inner view instead of the `ToolbarItem` itself — fix that.
- **Audit toolbar customizations** (fixed spacers, custom items) for consistency with system
  behavior.

### Windows and modals

- **Windows get rounder corners.** iPadOS now shows window controls and supports continuous
  resizing (no preset sizes; fluid down to a minimum).
- **Support arbitrary window sizes** — let users size to taste; adjust your content.
- **Use split views for fluid column resizing.** Standard split view APIs animate reflow
  beautifully.
- **Always specify safe areas** so the system can position window controls and the title bar
  correctly relative to your content.
- **Sheets adopt Liquid Glass:** larger corner radius; half-sheets are inset from the display
  edge to let content peek through; when expanded full-height, they become more opaque to focus
  attention.
- **Audit content near sheet edges** (rounder corners can clip).
- **Remove custom `UIVisualEffectView` backgrounds from popovers/sheets** for system
  consistency.
- **Action sheets now originate from the source control** (not the bottom edge of the display)
  and let the rest of the UI remain interactive. Always specify the source view/item.

### Organization and layout

- **Lists, tables, forms get larger row heights and padding.** Section corner radii match
  control curvature.
- **Section headers now use title-style capitalization automatically** for
  [`Section.init(content:header:)`](https://developer.apple.com/documentation/SwiftUI/Section/init(content:header:)).
  Update your text to title-style to match the system convention — your ALL-CAPS strings will no
  longer render as ALL-CAPS regardless.
- **Use SwiftUI `.formStyle(.grouped)`** to pick up the cross-platform form metrics for free.

### Search

- Platform-specific search location/behavior conventions are reinforced.
- **In iOS, when a search field is tapped it slides up with the keyboard** — verify your custom
  search UIs feel like the system.
- **Use semantic search tabs.** If search appears in a tab bar, use the standard "search tab"
  designation API — the system separates and places it at the trailing end, matching the rest
  of the OS.

### Platform-specific behavior

- **watchOS:** Liquid Glass changes are minimal and appear automatically on the new OS even
  without an SDK rebuild — but to actually pick up the appearance properly, adopt standard
  watchOS 10 toolbar APIs and button styles.
- **tvOS:** Standard buttons/controls take on Liquid Glass when focus moves to them. Adopt
  standard focus APIs on custom controls to participate. Supported on Apple TV 4K (2nd gen) and
  newer; older hardware keeps current appearance.
- **macOS:** Window controls, sheet insets, sidebar/inspector composition, and toolbar item
  grouping behavior follow the rules above.

### Custom Liquid Glass (when you really need it)

- Use [`GlassEffectContainer`](https://developer.apple.com/documentation/SwiftUI/GlassEffectContainer)
  to combine custom Liquid Glass effects in one container. This both optimizes rendering and
  enables fluid shape-morphing between adjacent glass shapes.
- **Performance-test on real devices across platforms** every time you rebuild against the new
  SDK. See
  [Improving your app's performance](https://developer.apple.com/documentation/Xcode/improving-your-app-s-performance).

### Deprecated patterns to remove

- Custom backgrounds on tab bars, toolbars, navigation bars, split-view sidebars, sheets, and
  popovers (`UIVisualEffectView` on popover content, custom blurs, etc.).
- Hard-coded control sizes, paddings, corner radii.
- ALL-CAPS section headers (the system now applies title-case automatically).
- Custom Liquid Glass / glass-blur effects rolled by hand outside of `GlassEffectContainer`.
- Empty toolbar items where you hide the inner view instead of the item.
- Action sheets anchored to the bottom edge instead of to their source control.
- Hand-built tab bar / sidebar layouts instead of using the auto-adapting tab/sidebar API and
  split views.

### Accessibility/legibility considerations

- Users can: pick a preferred Liquid Glass look, reduce transparency, reduce motion.
- Standard components honor all of these settings automatically.
- For custom elements: test under each setting. Verify color contrast remains adequate when
  transparency is reduced and when content scrolls behind controls.
- Provide an increased-contrast variant for each light/dark custom color you ship.

### iOS 27 / macOS 27 deltas — WWDC 2026 (fetched live 2026-06-12)

Sources: [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) (current rev),
[GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer),
[iOS & iPadOS 27 Beta Release Notes](https://developer.apple.com/go/?id=ios-27-rn),
WWDC26 coverage ([MacRumors](https://www.macrumors.com/2026/06/10/how-liquid-glass-is-changing-in-ios-27/)).

**Material/behavior changes (automatic — no recompile required for system-API adopters):**

- The material now diffuses complex content more aggressively (readability fix), and elements get
  a darkened edge + brighter specular highlights for separation. Apps already on system components
  or `glassEffect` inherit this **at runtime on 27**, even when built with the 26 SDK.
- Scroll-under: a uniform toolbar backing now appears when content scrolls beneath floating bars.
  Automatic for standard toolbars; tune only via the existing scroll edge effect APIs.
- **New user-facing transparency slider** (Settings): ultra-clear ↔ fully tinted. This widens the
  accessibility test matrix: custom-glass surfaces must stay legible across the slider range, not
  just under Reduce Transparency / Increase Contrast.

**API surface:**

- `glassEffect(_:in:)` / `GlassEffectContainer` (both `introducedAt: 26.0`): **no signature
  changes, no deprecations** in the 27 SDKs. Compositing-pipeline improvements propagate
  automatically. Mixed SwiftUI/UIKit apps should audit `GlassEffectContainer` boundaries for
  coherent morphing (FenixKanban is pure SwiftUI — not affected).
- SwiftUI on macOS 27 / iPadOS 27 **hides menu item symbol images by default** in most contexts
  (menu bar, context menus); a new API surfaces icons for key actions. Audit FK's macOS menu bar
  commands after moving to the 27 SDK.
- New picker style for tab-based navigation/content selection (27 SDKs).
- 27.0-SDK fix worth knowing: `controlSize`/`buttonSizing`/`menuIndicatorVisibility` etc.
  environment values now reset correctly in sheets and popovers.

**Icons:**

- Sharper rendering on 27 with **selective refraction** annotations. Icon Composer adds
  multi-layer glass, refraction/content-effect annotation, and previews of how an icon
  back-deploys to earlier OS releases. (Re-export of the FK icon is optional polish, not required.)

**Repo policy (Captain's ruling, 2026-06-12):**

- Deployment targets stay **iOS 26 / macOS 26**. The 27 deltas above do not require the 27 SDK at
  runtime for the glass improvements, so there is **no floor-raise pressure**. Any future use of
  27-only API (new picker style, menu-icon surfacing) gates behind `#available(iOS 27, *)` /
  `#available(macOS 27, *)`. If a future delta makes raising the floor tempting, file a
  `gray-area` + `needs-captain` issue — do not bump targets.
- Local toolchain reality (2026-06-12): Xcode 26.5 only, no iOS 27 simulator runtime. The
  transparency-slider test matrix entry is **deferred** until an Xcode 27 beta lands on the
  Mac mini; tracked in the mission log.

---

## App design and UI — SwiftUI

Source: [SwiftUI apps](https://developer.apple.com/documentation/technologyoverviews/swiftui)

- **SwiftUI is the recommended app-builder.** It is the preferred choice for visionOS and the
  required choice for watchOS.
- **App entry point is the [`App`](https://developer.apple.com/documentation/SwiftUI/App)
  struct.** Initialize app-wide data in its initializer; declare scenes in `body`. Keep
  initialization fast — push non-critical work to background tasks.
- **Pick the right scene type:** [`WindowGroup`](https://developer.apple.com/documentation/SwiftUI/WindowGroup)
  for normal apps, [`DocumentGroup`](https://developer.apple.com/documentation/SwiftUI/DocumentGroup)
  for document-based apps. Add more scenes for preference panes, tool palettes, alert windows.
- **Treat your data model as the source of truth.** Use the right property wrapper for each
  property (`@State`, `@Binding`, `@Environment`, `@Observable`, etc.) — SwiftUI re-renders
  driven by data changes.
- **Use `#Preview` macros** in every view file. Multiple previews per file, varying device,
  data, and appearance.
- **Animations are declarative**: specify what should animate; SwiftUI runs and reacts to
  changes mid-animation.
- **Interop both ways:** embed SwiftUI in UIKit/AppKit and vice-versa incrementally — no need
  to rewrite a working app to adopt new SwiftUI views.
- **Use technology-specific views** (Apple Pay button, etc.) instead of building lookalikes.

## App design and UI — UIKit and AppKit

Source: [UIKit and AppKit apps](https://developer.apple.com/documentation/technologyoverviews/uikit-appkit)

- UIKit and AppKit remain fully supported as traditional MVC frameworks; choose them for
  legacy/Objective-C codebases or where a specific kit fits better.
- **All UI work must run on the main thread.** Dispatch back to
  [`DispatchQueue.main`](https://developer.apple.com/documentation/Dispatch/DispatchQueue/main)
  before touching views.
- **Use [`UIDocument`](https://developer.apple.com/documentation/UIKit/UIDocument) /
  [`NSDocument`](https://developer.apple.com/documentation/AppKit/NSDocument)** for
  document-based apps to get autosave + menu integration for free.
- **In UIKit, use `UITraitCollection`** to make presentation decisions based on size class,
  appearance, and other traits — this is how iPad/iPhone size adaptation should happen.
- **Auto Layout / constraints** for view positioning — never hard-code frame sizes that won't
  survive size or orientation changes.
- **Use gesture recognizers** for input; use target-action for control events.
- **TextKit** for custom text rendering when standard text views aren't enough. Prefer standard
  text views — they integrate Writing Tools and other intelligent features automatically.
- **tvOS:** layer [TVUIKit](https://developer.apple.com/documentation/TVUIKit) on top of UIKit
  for TV-specific views.

## Interface fundamentals

Source: [Interface fundamentals](https://developer.apple.com/documentation/technologyoverviews/interface-fundamentals)

- **Three building blocks: Windows, Scenes, Views/Controls.** Plus *Volumes* in visionOS for
  3D content windows.
- **Store appearance-sensitive assets in asset catalogs.** Light/dark/high-contrast variants
  resolve automatically based on device and accessibility settings.
- **Bundle critical resources in the app; download large assets via
  [BackgroundAssets](https://developer.apple.com/documentation/BackgroundAssets)** after
  install — keeps the App Store download light.
- **Always implement these four foundational behaviors:**
  - *Automatic layout* (SwiftUI: built-in; UIKit/AppKit: Auto Layout).
  - *Internationalization* (use `Foundation` formatters, support RTL).
  - *Accessibility* (use built-in semantics, verify VoiceOver / focus paths).
  - *Undo support* via [`UndoManager`](https://developer.apple.com/documentation/Foundation/UndoManager).
  - *Pasteboard* (Cut/Copy/Paste integration).
- **Platform capability matrix** (verbatim from docs):
  - iOS/iPadOS support SwiftUI + UIKit. macOS supports SwiftUI + AppKit. tvOS supports SwiftUI +
    UIKit + TVUIKit. visionOS supports SwiftUI + UIKit. watchOS is SwiftUI-only.
  - Dark Mode: iOS/iPadOS/macOS/tvOS yes; visionOS no; watchOS no.
  - Scaling fonts automatically (Dynamic Type): iOS/iPadOS/visionOS/watchOS yes; macOS/tvOS no.
  - Multiple-windows support: iPadOS/macOS/visionOS yes; iOS only with an external display; tvOS
    and watchOS no.
  - Menus: iOS context-only; iPadOS main+context; macOS main+context+Dock; tvOS none; visionOS
    main+context; watchOS none.
- **Designing for visionOS:** start from a window for familiarity; add depth-based offsets
  selectively; use 3D content within views; add ornaments via
  [`.ornament(...)`](https://developer.apple.com/documentation/SwiftUI/View/ornament(visibility:attachmentAnchor:contentAlignment:ornament:))
  for tools/commands on window edges.
- **Designing for tvOS:** focus-driven; build with [Lockups](https://developer.apple.com/design/Human-Interface-Guidelines/lockups)
  so groups of related views move focus as one.
- **Designing for watchOS:** widgets, complications (`WidgetKit`), and notifications all matter
  as much as the main app interface. Support 38–45mm sizes and the Always-On state.

## Data management — Standard data types and processes

Source: [Standard data types and processes](https://developer.apple.com/documentation/technologyoverviews/standard-data-types-and-processes)

- **Use Swift Standard Library + Foundation types** for portability — they bridge cleanly
  between SwiftUI, UIKit, AppKit, and Objective-C.
- **Prefer `let` over `var`** by default. Immutable data is safe to pass across tasks/threads.
- **Adopt [`Codable`](https://developer.apple.com/documentation/Swift/Encodable) for serialization**
  of custom types. Objective-C: use `NSSecureCoding`.
- **Format with `FormatStyle`** (locale-aware) instead of hand-rolling number/date strings.
- **Build predicates with `#Predicate` macro** for filter/sort across SwiftData, Foundation
  collections, and more.
- **Encrypt at-rest data** with [`CryptoKit`](https://developer.apple.com/documentation/CryptoKit);
  set [`URLFileProtection`](https://developer.apple.com/documentation/Foundation/URLFileProtection)
  on every file you create.
- **Store secrets in Keychain** via [Keychain services](https://developer.apple.com/documentation/Security/keychain-services)
  — never in `UserDefaults` or files.
- **Validate all data from external sources** before incorporating into your data structures.

## Data management — Structured data models

Source: [Structured data models](https://developer.apple.com/documentation/technologyoverviews/structured-data-models)

- **For new SwiftUI apps, use SwiftData.** Annotate types with `@Model`; persist via
  [`ModelContainer`](https://developer.apple.com/documentation/SwiftData/ModelContainer); query
  via `@Query` directly in views.
- **CloudKit sync is one switch:** use
  [Syncing model data across a person's devices](https://developer.apple.com/documentation/SwiftData/Syncing-model-data-across-a-persons-devices)
  in SwiftData, or
  [Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/CoreData/mirroring-a-core-data-store-with-cloudkit)
  in Core Data.
- **SwiftData supports undo natively** —
  [revert via the undo manager](https://developer.apple.com/documentation/SwiftData/Reverting-data-changes-using-the-undo-manager).
- **Use Core Data** when working in Objective-C, or when you need its model-editor and
  fine-grained capabilities and aren't on SwiftUI.
- **SQLite is in every SDK** if you need a raw relational DB.
- **Concurrency:** apply
  [SwiftData concurrency support](https://developer.apple.com/documentation/SwiftData/ConcurrencySupport)
  so fetch/save behaves correctly across actors and tasks.

## Data management — Files and directories

Source: [Files and directories](https://developer.apple.com/documentation/technologyoverviews/files-and-directories)

- **All disks are presented as APFS-like by Foundation.** Use Foundation APIs, not raw paths.
- **Build paths from well-known directories** via `URL` / `FileManager` (container, documents,
  caches, application support, temporary). Never build from `/` or the working directory.
- **Treat filenames as case-sensitive in code.** APFS is case-insensitive by default but users
  can flip it.
- **Always include filename extensions** — the system routes files by extension.
- **Never use display names in file paths or code** — display names are UI-only.
- **App Sandbox (macOS) requires `Accessing files from the macOS App Sandbox`**-style scoped
  URLs; iOS apps always run sandboxed.
- **Use [`Bundle`](https://developer.apple.com/documentation/Foundation/Bundle)** to find
  resources; let it handle platform layout + localization (`.lproj`).
- **Use asset catalogs** to manage images, colors, icons — request by name, get the right
  variant.
- **File packages** (directory presented as one file): set
  [`LSTypeIsPackage`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleDocumentTypes/LSTypeIsPackage)
  in the document type definition.
- **Background Assets framework** for large/optional/separately-shipped data and ML models.
- **Always set [`URLFileProtection`](https://developer.apple.com/documentation/Foundation/URLFileProtection)** on
  every file you write — choose the strictest level the data permits.

## Data management — Shared data

Source: [Shared data](https://developer.apple.com/documentation/technologyoverviews/shared-data)

- **iCloud has multiple complementary APIs — choose based on data shape:**
  - **Game-save / structured directory:** [`GameSave`](https://developer.apple.com/documentation/GameSave) framework.
  - **Small scalar/preference data:** [`NSUbiquitousKeyValueStore`](https://developer.apple.com/documentation/Foundation/NSUbiquitousKeyValueStore)
    (max 1024 keys / 1 MB total).
  - **User documents:** iCloud document storage via
    [`FileManager.url(forUbiquityContainerIdentifier:)`](https://developer.apple.com/documentation/Foundation/FileManager/url(forUbiquityContainerIdentifier:)).
  - **App data structures:** SwiftData with CloudKit, or Core Data + CloudKit, or CloudKit
    directly (up to 1 PB public data; CloudKit JS for web). Run integration tests via Xcode/CI.
- **Cross-app / app-extension data sharing** requires
  [App Groups Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups);
  use [`containerURL(forSecurityApplicationGroupIdentifier:)`](https://developer.apple.com/documentation/Foundation/FileManager/containerURL(forSecurityApplicationGroupIdentifier:)).
  App groups also enable IPC (Mach IPC, POSIX shared memory, UNIX sockets).
- **File coordination is required for shared files.** Either adopt the document types (which
  coordinate automatically) or implement
  [`NSFilePresenter`](https://developer.apple.com/documentation/Foundation/NSFilePresenter) +
  [`NSFileCoordinator`](https://developer.apple.com/documentation/Foundation/NSFileCoordinator).
- **Custom document formats**: use file packages, keep format platform-agnostic, include a
  version number, store relevant app state (not transient scroll position).
- **Remote file servers:** ship a [File Provider extension](https://developer.apple.com/documentation/FileProvider)
  inside your app.

## Data management — Personal data

Source: [Personal data](https://developer.apple.com/documentation/technologyoverviews/personal-data)

- **Every personal-data API requires a specific usage-description string in `Info.plist`** —
  set BEFORE you call the request API.
- **Write usage descriptions that explain WHY** in plain language. The system shows the
  description in the consent dialog.
- **Key data types and their frameworks:**
  - Contacts → `Contacts` / `ContactsUI` (`NSContactsUsageDescription`)
  - Calendar → `EventKit` (`NSCalendarsFullAccessUsageDescription` /
    `NSCalendarsWriteOnlyAccessUsageDescription`)
  - Health → `HealthKit` (multiple keys per access type)
  - Location → `CoreLocation` (`NSLocationWhenInUseUsageDescription` /
    `NSLocationAlwaysAndWhenInUseUsageDescription` / `NSLocationTemporaryUsageDescriptionDictionary`)
  - Music → `MusicKit` / `Apple Music API` (`NSAppleMusicUsageDescription`)
  - Photos → `PhotoKit` (`NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`)
  - Reminders → `EventKit` (`NSRemindersFullAccessUsageDescription`)
  - Game Center friends → `GameKit` (`NSGKFriendListUsageDescription`)
- **Vision Pro environment data:** route through `ARKit` — direct camera/LiDAR access is
  restricted for privacy.
- **Identity verification:** use the Verify with Wallet API + `PassKit` (with entitlement);
  custom credential providers go through `IdentityDocumentServices` /
  `IdentityDocumentServicesUI`. Reading IDs off another iPhone uses `ProximityReader`.

## Core experiences — Convenience

Source: [Convenience](https://developer.apple.com/documentation/technologyoverviews/convenience)

- **Universal links are foundational** — required for Handoff, App Clips, Shared with You, web
  credential sharing.
- **Two-way validation required:** add the
  [Associated Domains Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.associated-domains)
  and configure the website-side association file.
- **Always validate URLs your app receives** to prevent malicious content.
- **Handoff** = `NSUserActivity` + enabling `isEligibleForHandoff` + `becomeCurrent()`. Keep
  payloads tiny — transfer URLs, not document bytes.
- **Quick Look Preview app extension** for custom document formats. Standard formats (PDF/text/
  image/audio/video/USDZ) already have previews.
- **Sign in with Apple:** offer it wherever you collect username/password. Use
  [`AuthenticationServices`](https://developer.apple.com/documentation/AuthenticationServices),
  Sign in with Apple JS, or the REST API depending on platform.
- **Auto sign-in for media accounts:** `VideoSubscriberAccount` framework stores a token on the
  Apple ID — all the user's devices can sign in automatically.
- **Shared with You:** adopt universal links + the entitlement; use `SWHighlightCenter` to
  surface links shared in Messages and `SWAttributionView` to credit/return to the sender.
- **App Clips** are tiny single-task targets; keep them small; require universal links; can
  send notifications and host Live Activities.

## Core experiences — Communication and connection

Source: [Communication and connection](https://developer.apple.com/documentation/technologyoverviews/communication-and-connection)

- **Local notifications** via `UserNotifications`. **Custom alarms/timers**: use
  [`AlarmKit`](https://developer.apple.com/documentation/AlarmKit) (snoozable, cancellable
  countdowns with custom UI).
- **Push notifications via APNs.** Background pushes wake your app for silent updates — the
  system polices runtime to preserve battery.
- **Always request permission contextually** (when the feature that needs notifications is
  enabled), not at launch. Honor the user's response server-side.
- **Siri integration is via `AppIntents`.** Convert your data types to `AppEntity` and your
  actions to `AppIntent` — no architectural rewrite required. HomePod streaming music: also
  support `SiriKitCloudMedia`.
- **SharePlay:** `GroupActivities` framework. Your app drives the per-participant UI; the
  system synchronizes state. Use `AVFoundation` for media sync.

## Core experiences — Information

Source: [Information](https://developer.apple.com/documentation/technologyoverviews/information)

- **Index your content in Core Spotlight** even if you don't have a search UI — this enables
  system Spotlight, Siri responses, and Apple Intelligence semantic search over your content.
  Core Spotlight indexes are local-only (no Apple/iCloud sync).
- **Index `NSUserActivity` objects** with `isEligibleForSearch = true` for actions/screens
  users visit.
- **Surfaces beyond the app:** Widgets (`WidgetKit`), watch complications, Live Activities
  (`ActivityKit` + APNs), Control Center / Lock Screen / Action button controls. All run as
  app extensions and should be designed to run independently of the main app.
- **Smart Stack widgets** can be elevated by location/time/condition signals — supply
  contextual clues to be promoted at the right moment.
- **In-line context frameworks** to know about:
  - `MapKit` for embedded maps and turn-by-turn; `GeoToolbox` for placenames.
  - `WeatherKit` for forecasts.
  - `TipKit` for feature discovery (not a substitute for help docs).
  - `LinkPresentation` (`LPLinkView`) for rich URL previews — feed metadata to the share sheet.
  - `DataDetection` for flight numbers, tracking codes, phone numbers, dates, emails, URLs.
  - `EnergyKit` for grid-power forecasts (EV/thermostat/home-energy apps).
- **Parental controls / Screen Time:** `ScreenTime`, `FamilyControls`, `DeclaredAgeRange`,
  `PermissionKit`.

## Core experiences — App and system extensions

Source: [App and system extensions](https://developer.apple.com/documentation/technologyoverviews/app-extensions)

- **An app extension is a separate bundle inside your app.** The system runs it as a separate
  process — it doesn't automatically share your app's resources or permissions.
- **Design extensions to run independently.** Fetch from the network rather than relying on
  shared state. Share only via app groups when truly necessary.
- **The Extension Points table is the authoritative list** of supported extension types and
  their platform availability. Highlights:
  - `AppIntents` — Siri / Shortcuts / focus filters
  - `WidgetKit` — widgets, controls, watch complications, Live Activities
  - `CSImportExtension` — Spotlight content provider
  - `LockedCameraCapture` — Camera launch from Lock Screen / Action button / Control Center
  - `MediaExtension` (macOS) — codec support for formats the system doesn't ship
  - `ContactProviderExtension` (iOS 26) — provide contact items system-wide
  - `MEExtension` (macOS) — Mail extensions
- **Custom extensions hosted by your app**: use `ExtensionFoundation` + `ExtensionKit`.
- **System extensions** (`NetworkExtension`, `EndpointSecurity`, `DriverKit`-based dexts)
  replace KEXTs. Use `SystemExtensions` framework to install/upgrade on macOS; on iPadOS the
  system discovers and upgrades them automatically. Always-on entitlements required.

## AI/ML — Apple Intelligence

Source: [Apple Intelligence](https://developer.apple.com/documentation/technologyoverviews/apple-intelligence)

- **Use system frameworks → Apple Intelligence comes free.** Standard text views ship with
  Writing Tools. Genmoji embed automatically as
  [`NSAdaptiveImageGlyph`](https://developer.apple.com/documentation/UIKit/NSAdaptiveImageGlyph).
- **Persist Genmoji in custom file formats** by handling `NSAdaptiveImageGlyph` attachments —
  otherwise they'll be lost when saving.
- **Writing Tools on custom text views:** adopt the API in
  [Adding Writing Tools support to a custom UIView](https://developer.apple.com/documentation/UIKit/adding-writing-tools-support-to-a-custom-uiview);
  use attributed strings as your backing store.
- **Visual Intelligence:** integrate via `VisualIntelligence` framework + `AppIntents` so the
  user's Camera Control scans can surface results from your app.
- **Image Playground:** present the system UI via the `ImagePlayground` framework, or generate
  programmatically via `ImageCreator` (async).

## AI/ML — Intelligent frameworks

Source: [Intelligent frameworks](https://developer.apple.com/documentation/technologyoverviews/intelligent-frameworks)

- **Don't build ML from scratch — try a system framework first.** Apple-trained on-device
  models cover 25+ image analysis tasks (`Vision`/`VisionKit`), 300+ sound classes
  (`SoundAnalysis`), and more.
- **Vision/VisionKit:** Live Text, document scanning, object/face/body tracking, image
  aesthetics, trajectory detection.
- **`SensitiveContentAnalysis`** for detecting nudity / providing intervention options before
  showing media.
- **Speech-to-text:** `Speech` framework + `SpeechAnalyzer`. Streaming + on-device, optimized
  for long-form / distant audio (meetings, lectures).
- **ShazamKit** for music/audio recognition (Shazam catalog or your own custom catalog via
  `SHSignature`).
- **NaturalLanguage** for tokenization, language ID, similarity search across text.
- **Translation framework:** on-device translation between
  [`supportedLanguages`](https://developer.apple.com/documentation/Translation/LanguageAvailability/supportedLanguages).
  Use [`.translationPresentation(...)`](https://developer.apple.com/documentation/SwiftUI/View/translationPresentation(isPresented:text:attachmentAnchor:arrowEdge:replacementAction:))
  for inline UI or [`.translationTask(...)`](https://developer.apple.com/documentation/SwiftUI/View/translationTask(source:target:action:))
  for direct sessions; supports
  [`translate(batch:)`](https://developer.apple.com/documentation/Translation/TranslationSession/translate(batch:))
  for bulk.

## AI/ML — Foundation Models

Source: [Foundation Models](https://developer.apple.com/documentation/technologyoverviews/foundation-models)

- **Foundation Models = the on-device LLM that powers Apple Intelligence**, exposed to your app.
- **Guided generation** — define a Swift type and the model emits matching structured data; no
  hand-written parsing. See
  [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/FoundationModels/generating-swift-data-structures-with-guided-generation).
- **Tool calling**: register Swift functions the model can call mid-generation (e.g. fetch
  calendar events, look up products). See
  [Expanding generation with tool calling](https://developer.apple.com/documentation/FoundationModels/expanding-generation-with-tool-calling).
- **Custom adapters** for domain specialization, trained via the Foundation Models Adapter
  Training Toolkit.
- **Use `LanguageModelSession`** as the primary entry point; iterate on prompts.

## AI/ML — Machine learning models

Source: [Machine learning models](https://developer.apple.com/documentation/technologyoverviews/machine-learning)

- **Core ML is the deployment target.** All custom models must be in Core ML format on-device.
- **Use Create ML / Create ML Components** (or the Create ML app: Xcode → Open Developer Tool →
  Create ML) for no-code training of image, sound, text, action, tabular classifiers.
- **PyTorch/MLX/etc. models:** convert via Core ML Tools — handles compression, on-device
  optimization, smaller size, lower power, lower latency.
- **Xcode previews ML models live** with sample data, camera, or microphone. Use the Model
  Performance tab to see latency/load times per operation and check which run on
  CPU/GPU/Neural Engine.
- **Heavy graphics + ML:** combine Core ML with `MetalPerformanceShadersGraph` and `Metal`.
- **Real-time signal processing on CPU:** `BNNS Graph` API in `Accelerate`.

## Audio and video — Video

Source: [Video](https://developer.apple.com/documentation/technologyoverviews/video)

- **`AVAsset` + `AVPlayer` are the playback foundation.** Use them with files, remote files, or
  HLS streams uniformly.
- **HEVC is the recommended codec for 4K/HDR**; AVC also hardware-accelerated.
- **Use [`AVPlayerViewController`](https://developer.apple.com/documentation/AVKit/AVPlayerViewController)
  (iOS/tvOS/visionOS) / [`AVPlayerView`](https://developer.apple.com/documentation/AVKit/AVPlayerView)
  (macOS) for the system player UI** — gets AirPlay, Picture-in-Picture, remote control, Lock
  Screen, and SharePlay integration for free.
- **Custom UIs must still adopt:** `AVKit` for PiP + `AVRoutePickerView`, `Media Player` for
  `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`, `Media Accessibility` for caption
  preferences.
- **Capture pipeline = `AVCaptureSession` + inputs + outputs.** On iPhone 16+, support the
  Camera Control button (`AVCaptureEventInteraction`). Use `LockedCameraCapture` to launch
  from Lock Screen / Action button / Control Center.
- **Screen capture:** `ReplayKit` (iOS/macOS/tvOS, broadcast-friendly) or `ScreenCaptureKit`
  (macOS only, high-performance, low-latency, fine-grained).
- **Editing:** `AVComposition` for timeline editing; `AVMovie` for direct QuickTime file
  manipulation.
- **Save captures to Photos** via `PhotoKit`.

## Audio and video — Audio and music

Source: [Audio and music](https://developer.apple.com/documentation/technologyoverviews/audio-and-music)

- **UI sounds (≤30s, uncompressed):** `AudioServices.AudioServicesPlaySystemSound`.
- **Files of any length, with controls:** `AVAudioPlayer`.
- **Haptics:** prefer SwiftUI [`SensoryFeedback`](https://developer.apple.com/documentation/SwiftUI/SensoryFeedback) /
  UIKit `UIFeedbackGenerator` for standard interactions; use `CoreHaptics` for custom patterns.
- **MusicKit** for Apple Music catalog + user library access (Swift, JS, Android SDKs).
- **`AVAudioEngine`** for node-based mixing, effects, real-time processing. Captures buffers
  cleanly into `SoundAnalysis` / `Speech`.
- **Spatial audio: pick the right framework:**
  - **RealityKit Audio** — entity-attached, head-tracked, occlusion-aware. Best for visionOS
    and games using RealityKit scenes.
  - **`AVAudioEngine` with `AVAudioEnvironmentNode`** — flexible node-based 3D positioning,
    reverb, distance attenuation. Best for mixed-needs apps.
  - **`PHASE`** — advanced 3D acoustic simulation. Best for highly immersive games.
- **Speech:** `AVSpeechSynthesizer` (TTS) and `Speech` framework (STT, on-device or cloud).
- **MIDI:** `AVAudioUnitSampler` for MIDI-driven playback; `AudioToolbox` `MusicSequence` /
  `Music Player` for sequencing; `CoreMIDI` for device I/O over USB/BT/network.
- **Audio Unit plug-ins:** prefer Audio Unit v3 (AUv3) — App Extension model. Host via
  `AudioComponents` + `AVAudioUnit`.

## Audio and video — Spatial and immersive media

Source: [Spatial and immersive media](https://developer.apple.com/documentation/technologyoverviews/immersive-media)

- **Spatial video capture** is a regular `AVFoundation` capture pipeline with the
  spatial-video extensions. Save to Photos via `PhotoKit`.
- **Playback on Vision Pro:** same `AVKit` / `AVFoundation` pipeline as elsewhere; on visionOS
  `AVPlayerViewController` provides an
  [`AVExperienceController`](https://developer.apple.com/documentation/AVKit/AVExperienceController)
  for multi-view ↔ immersive transitions.
- **Custom 3D players:** use `RealityKit`'s
  [`VideoPlayerComponent`](https://developer.apple.com/documentation/RealityKit/VideoPlayerComponent).
- **Quick Look** (`PreviewApplication`) gives you free spatial-video previews without a custom
  player.
- **Apple Immersive Video** (8K/eye, head-tracked, Spatial Audio): adopt
  [`ImmersiveMediaSupport`](https://developer.apple.com/documentation/ImmersiveMediaSupport)
  to read/write the required metadata and preview from a Mac onto Vision Pro before final
  output.

## Audio and video — Media streaming

Source: [Media streaming](https://developer.apple.com/documentation/technologyoverviews/streaming)

- **AirPlay support is largely free** when you adopt `AVFoundation` +
  [Configuring your app for media playback](https://developer.apple.com/documentation/AVFoundation/configuring-your-app-for-media-playback)
  and use `AVKit` for the device picker.
- **HLS is the recommended streaming format.** It supports adaptive bitrate, FairPlay DRM,
  closed captions, multiple audio/video variants, low-latency mode.
- **Low-Latency HLS** for gaming/auctions/live events — see
  [Enabling Low-Latency HTTP Live Streaming (HLS)](https://developer.apple.com/documentation/HTTP-Live-Streaming/enabling-low-latency-http-live-streaming-hls).

## Hardware — Device sensors

Source: [Device sensors](https://developer.apple.com/documentation/technologyoverviews/device-sensors)

- **Every sensor framework requires a usage-description string** in `Info.plist` (camera,
  microphone, NFC, location, motion, fall detection, SensorKit, Bluetooth, world sensing).
- **Enable sensors only when needed; disable as soon as done.** Use the lowest-precision /
  lowest-frequency API your feature can tolerate — saves battery and avoids privacy escalation.
- **Location:** use multiple Core Location services together (e.g., region monitoring +
  precision updates only inside the region).
- **`MKReverseGeocodingRequest`** or `GeoToolbox` to turn coordinates into addresses.
- **Motion:** `CoreMotion` for live data (accelerometer/gyro/magnetometer/barometer);
  `SensorKit` for longer-window analysis (ambient light, wrist temperature, heart rate,
  device-usage metrics).
- **AR / world capture:** `ARKit` (live AR), `VisionKit` / `Vision` (image/video analysis),
  `RoomPlan` (3D room model — must show a `RoomCaptureView`; can't quietly scan).
- **Tap to Pay / NFC payments:** `ProximityReader` framework. Custom NFC tags / payloads:
  `CoreNFC`.
- **iBeacon:** Core Location supports proximity-based triggers in the framework — useful for
  museum-style, place-of-business apps.

## Hardware — Networking and communication

Source: [Networking and communication](https://developer.apple.com/documentation/technologyoverviews/networking-and-communication)

- **`URLSession` (URL Loading System) is the default.** It handles auth, cookies, caches, and
  background downloads. Configure with `URLSessionConfiguration` to control allowed networks
  (e.g., Wi-Fi only).
- **Drop to `Network` framework (`NWConnection` / `NWListener`)** only when you need protocol
  control (QUIC, TCP, UDP, custom), low latency, multicast, or graceful network-transition
  handling. Mail/messaging/games typically need this.
- **Bonjour zero-config networking** is built into the `Network` framework — advertise via
  `NWListener`, discover via `NWEndpoint`.
- **Network Extensions** (VPN, content filters, DNS configuration, hotspot helpers, relays,
  local push) live in `NetworkExtension` and must be packaged as app extensions.
- **VoIP / dialer:** use `LiveCommunicationKit` (newer) — register your app to be a default
  dialer/calling app; gain access to the conversation history.
- **`CallKit` remains valid** for non-VoIP call routing.

## Hardware — Hardware-level interactions

Source: [Hardware-level interactions](https://developer.apple.com/documentation/technologyoverviews/hardware-level-interactions)

- **Accessory access:** `ExternalAccessory` framework + an `EASession`. MFi accessories may
  expose both standard and manufacturer-specific protocols — pick the right one.
- **Custom hardware drivers:** build a *driver extension (dext)* using DriverKit SDK
  (`DriverKit`, plus `USBDriverKit`, `HIDDriverKit`, `PCIDriverKit`, `AudioDriverKit`,
  `MIDIDriverKit`, etc.). On macOS, install via `SystemExtensions`. On iPadOS, the system
  discovers dexts in your app automatically.
- **KEXTs are deprecated — always prefer dexts.** Even bugs in dexts can break devices, so
  test thoroughly.
- **Apple silicon optimization:** iOS apps can run on Mac via "Designed for iPad" — adapt them
  via
  [Adapting iOS code to run in the macOS environment](https://developer.apple.com/documentation/Apple-Silicon/adapting-ios-code-to-run-in-the-macos-environment).
- **For performance-critical code on Apple silicon:** see
  [Tuning your code's performance for Apple silicon](https://developer.apple.com/documentation/Apple-Silicon/tuning-your-code-s-performance-for-apple-silicon)
  and the
  [Apple Silicon CPU Optimization Guide v4](https://developer.apple.com/documentation/Apple-Silicon/cpu-optimization-guide).
  Mind page sizes, cache lines, variadic functions, simultaneously-writable-and-executable
  memory.

## Games — Game technologies

Source: [Game technologies](https://developer.apple.com/documentation/technologyoverviews/games-technologies)

- **Use Metal for rendering**; `MetalFX` for upscaling/temporal antialiasing; built-in ray
  tracing for advanced lighting.
- **Tailor for tile-based deferred rendering.** Apple GPUs reward imageblocks, tile shading,
  raster order groups — don't write code that assumes immediate-mode hardware.
- **Profile early and often** with Xcode Metal debugger, Metal Performance HUD, Instruments.
- **visionOS games:** use `RealityKit` + `SwiftUI` + `ARKit` for AR; `Metal` +
  `CompositorServices` for fully custom rendering; ARKit for spatial input.
- **Audio:** `PHASE` for game-grade spatial audio; `AVFAudio` for music + SFX; RealityKit
  scene-attached audio for AR scenes.
- **Haptics:** `CoreHaptics` for in-app; `GameController.GCDeviceHaptics` for controller
  haptics.
- **Input:** `GameController` framework — supports third-party gamepads, arcade sticks, racing
  wheels, mouse, keyboard; can overlay a virtual controller; supports advancements like
  controller-driven haptics.
- **Distribution:** Apple silicon-only macOS games go in a dedicated App Store section. Always
  notarize macOS games and enable Hardened Runtime.

## Games — Building macOS game remotely from PC

Source: [Building your macOS game remotely from your PC](https://developer.apple.com/documentation/technologyoverviews/building-your-macos-game-remotely-from-your-pc)

- **For Windows-based teams porting to macOS.** Setup requires macOS Sequoia 15.4+, Xcode 26+,
  zsh as default shell, the Game Porting Toolkit 3.0 installer, Metal Shader Converter (if you
  build DXIL shaders), Remote Management + Remote Login on in Sharing settings.
- **On Windows:** Visual Studio 2022 17.14+, with "Linux and embedded development with C++"
  workload, configured to use CMake presets and connecting to the Mac via Cross Platform >
  Connection Manager. User must be in `admin` or `_developer` group on the Mac for debugging.
- **Project must be CMake-based.** Author a `CMakeLists.txt` and a `CMakePresets.json`
  configured for `lldb-dap` debugger.
- **Parallel building:** add `-j` to CMake build command arguments in Visual Studio.
- **VNC access:** use a third-party VNC client (Microsoft RDP doesn't support VNC). Connect a
  physical display when possible — VNC doesn't carry game-controller events.

---

## Implementation Rules Quick Reference

The highest-leverage rules across all topics, in order of "things to do first when adopting
iOS 26 / macOS 26":

- **Rebuild against the latest SDKs in the latest Xcode — standard SwiftUI/UIKit/AppKit
  components pick up Liquid Glass automatically.** If you need a temporary opt-out, set the
  `UIDesignRequiresCompatibility` Info.plist key.
- **Remove custom backgrounds from tab bars, toolbars, navigation bars, sidebars, sheets, and
  popovers** — they fight Liquid Glass and the system scroll edge effect.
- **Never roll your own Liquid Glass / glass-blur effect by hand.** If you must, wrap every
  custom glass view inside a single `GlassEffectContainer` for correctness and performance.
- **Stop hard-coding control sizes, paddings, corner radii, and ALL-CAPS section headers** —
  sections now title-case automatically and controls reshape themselves.
- **Hide whole `ToolbarItem`s — never just their inner content.** Use the new toolbar grouping
  and fixed-spacer APIs instead of hand-built spacing.
- **Use the auto-adapting tab-bar↔sidebar API + split views** instead of custom navigation
  containers; that's how you get Liquid Glass behavior plus continuous resizing for free
  (especially in iPadOS / macOS).
- **Action sheets must originate from their source control**, not the bottom edge — set the
  source view/item.
- **Redesign your app icon with Icon Composer in layered, semi-transparent shapes.** Do not
  pre-bake shadows/blurs; let the system apply them. Provide light/dark/clear/tinted variants.
- **Every personal-data or sensor API requires a usage-description string in Info.plist.**
  Write descriptions that explain *why*; the system shows them in the consent dialog.
- **Index everything in Core Spotlight** — including `NSUserActivity` objects — for free
  Spotlight, Siri, and Apple Intelligence semantic search exposure.
- **For new persistence: SwiftData with `@Model` + `@Query`.** Toggle CloudKit sync via one
  modifier. Adopt undo via the model context.
- **Prefer standard text views for all text input** — Writing Tools, Genmoji, and Translation
  integrate for free. Custom text views must adopt the Writing Tools API and persist
  `NSAdaptiveImageGlyph` attachments.
- **Test every screen under reduce-transparency, reduce-motion, and the alternate Liquid
  Glass appearance settings** — these are user-controllable and they change the rendering of
  custom views in ways standard components handle automatically.
- **Profile after the SDK rebuild.** Liquid Glass and the new rendering pipeline shift CPU/GPU
  costs; use Instruments and the Metal Performance HUD before shipping.
- **Adopt App Intents (`AppEntity` / `AppIntent`) for any user-facing action or piece of
  content** — this is the single entry point that surfaces your app to Siri, Shortcuts,
  Spotlight, Focus Filters, and Apple Intelligence.
