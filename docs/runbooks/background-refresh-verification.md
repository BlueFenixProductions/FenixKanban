# Background Refresh Verification Runbook

Task: #62 — `com.bluefenixproductions.FenixKanban.fizzy-refresh`

## Overview

`BGAppRefreshTask` cannot be unit-tested (it requires a physical device and
the OS scheduling subsystem). This runbook covers the manual verification
recipe using LLDB's private `_simulateLaunchForTaskWithIdentifier:` API, plus
the prerequisites and known platform constraints.

---

## Prerequisites

1. **Device**: A physical iPhone/iPad running iOS 26 or later.
   - Simulator support for BGTaskScheduler simulation exists but is unreliable
     on iOS 26 sim builds. Physical device is strongly preferred.
   - Susanoo (the test iPhone) runs iOS 27 beta; see the Xcode version note
     below.

2. **Settings on device**:
   - Settings > General > Background App Refresh: **ON** (globally)
   - Settings > FenixKanban > Background App Refresh: **ON**
   - Low Power Mode: **OFF** (BGAppRefreshTask is suspended in Low Power Mode)

3. **Xcode version**:
   - The LLDB simulation command requires an Xcode that can attach to the
     running process. Xcode 26.5 (currently on the Mac) can attach to iOS 26
     devices.
   - Susanoo runs iOS 27 beta. Attaching Xcode 26.5 to an iOS 27 beta device
     may fail with a "mismatched OS" error. **Verification against Susanoo may
     require Xcode 27 beta once available.**
   - If Xcode 27 beta is installed at a separate path, set
     `DEVELOPER_DIR=/path/to/Xcode27.app/Contents/Developer` before running
     `xcodebuild` and `lldb`.

4. **App must be paused in background** (not force-quit):
   - Launch FK, navigate to a board, press the Home button.
   - Do NOT swipe up to force-quit — the OS will not wake a terminated app
     via BGAppRefreshTask.

---

## Simulation Recipe (LLDB)

### Step 1 — Attach Xcode to the device and build for debugging

```
xcodebuild -project FenixKanban.xcodeproj \
  -scheme FenixKanban \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  build
```

Or simply run from Xcode (Product > Run) with the device selected.

### Step 2 — Pause execution in Xcode's debugger

In Xcode, click the pause button in the debug toolbar (or press ⌃⌘Y) **after**
the app has moved to background (Home button pressed). The process must be
suspended, not running, for the simulation command to work.

### Step 3 — Fire the simulation command in the LLDB console

In Xcode's LLDB console (the input area at the bottom of the debug area):

```objc
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.bluefenixproductions.FenixKanban.fizzy-refresh"]
```

Then resume execution (⌃⌘Y or click Continue).

### Step 4 — Observe the handler

The app's `.backgroundTask(.appRefresh(…))` handler in `FenixKanbanApp` will
fire. Expected log output in Xcode console:

```
[BgRefresh] performBackgroundRefresh started
```

If the provider is paired and the sync completes within 25 s, the handler
returns `true`. The OS marks the task complete.

If the identifier is not registered (plist misconfiguration), the simulation
command silently fails and no handler fires.

---

## Verifying the plist keys

The `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` (`fetch`)
keys live in `FenixKanban/Resources/Info-Partial.plist`. This file is merged
into the auto-generated `Info.plist` by Xcode's `INFOPLIST_FILE` +
`GENERATE_INFOPLIST_FILE=YES` build setting combination.

### macOS build — no UIBackgroundModes leak

The `Info-Partial.plist` is only referenced by the `FenixKanban` iOS target
(`project.yml` target `FenixKanban`, platform `iOS`). The macOS target is the
same binary via Catalyst/multi-platform settings but the plist merge is iOS
simulator / device only. To verify after a macOS build:

```bash
# Build for macOS (no signing)
xcodebuild -project FenixKanban.xcodeproj \
  -scheme FenixKanban \
  -destination 'platform=macOS,variant=Mac Designed for iPad' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

# Extract the embedded Info.plist from the macOS app bundle
MACOS_APP=$(find ~/Library/Developer/Xcode/DerivedData/FenixKanban-*/Build/Products -name "FenixKanban.app" -path "*/Debug*macos*" | head -1)
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$MACOS_APP/Contents/Info.plist" 2>&1
# Expected: "Print: Entry, ":UIBackgroundModes", Does Not Exist"
# (UIBackgroundModes is ignored/absent on macOS)
```

Note: `BGTaskSchedulerPermittedIdentifiers` is also iOS-only; macOS ignores
it even if present. The `UI*` keys are the critical ones for leak verification.

---

## Scheduler scheduling logic

The request is submitted in two places in `FenixKanbanApp`:

1. **On `.background` scenePhase** — every time the app backgrounds, a new
   request is submitted with `earliestBeginDate = now + 15 minutes`.
2. **After each BGAppRefreshTask handler run** — to keep the queue populated
   for the next cycle.

`BGTaskScheduler.shared.submit(_:)` is idempotent for a given identifier when
a pending request already exists — duplicate submits are silently coalesced.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| LLDB command prints no output and no handler fires | App was force-quit (not backgrounded) |
| Handler fires but sync does not run | `FizzySyncProvider.isPaired == false` — check Fizzy token + slug in Settings |
| Handler fires but returns false immediately | Budget timeout — check network conditions |
| `BGTaskScheduler.submit` fails with error 3 | `BGTaskSchedulerPermittedIdentifiers` missing from plist, or identifier mismatch |
| Xcode 26.5 can't attach to iOS 27 beta device | Install Xcode 27 beta and re-run |
