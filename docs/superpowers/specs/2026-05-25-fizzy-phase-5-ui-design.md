# Fizzy Integration — Phases 4c & 5 Design

**Scope:** Two PRs that complete the Fizzy integration story. Phase 4c lays a
safety floor (verified backup + sync-isolation tests) so Phase 5's UI can be
exercised against real data without fear. Phase 5 wires
`FizzySyncEngine` (Phase 4a/4b) into the app via `FizzySyncProvider` and
three new SwiftUI surfaces.

**Status:** Design — pre-plan.
**Date:** 2026-05-25
**Spec series:** Continuation of
`docs/superpowers/specs/2026-05-25-fizzy-api-integration-design.md`.

---

## Why a Phase 4c

The original spec's Phase 5 covered "UI + first-time pointing at real
fizzy.bluefenix.net". During brainstorming we surfaced two concrete risks:

1. **`syncFirst(mode: .replaceLocalWithFizzy)` is destructive.** If invoked
   against the wrong local board or with wrong expectations, it wipes the
   paired board's cards. Phase 5 will be the first time this code runs
   against the real user's data, on the real server.
2. **Isolation isn't proven.** The engine takes a single `localBoard`, but
   no test currently asserts that *other* local boards are untouched when
   sync runs against the paired one.

Phase 4c lands both safeguards before any UI changes ship:

- An "Export backup" feature in Settings with a built-in verifier (open the
  written backup, count entities, compare to live store, refuse to claim
  success on mismatch).
- A `FizzySyncEngineBoardIsolationTests` suite that locks the
  "non-paired boards never touched" invariant for all four sync entry
  points (`syncFirst` × 3 modes + `sync`).

Phase 5 then builds the UI knowing the recovery path and isolation
guarantee are in place.

---

## Phase 4c — Backup + Safety

### Goals

1. User can export a `.fenixkanban-backup` file from Settings.
2. The exporter immediately re-reads the file and verifies a round-trip
   (entity counts match live store, schema parses).
3. Restore is a documented manual process — no in-app restore UI yet.
4. New tests prove that sync operations only touch the paired board.

### New files

```
FenixKanban/Features/Backup/
├── BackupExporter.swift           (~180 LOC — zip+verify the CoreData store)
└── BackupSettingsView.swift       (~100 LOC — Settings entry, Export button, status)

FenixKanbanTests/Features/Backup/
└── BackupExporterTests.swift      (~4 tests: success round-trip, truncated rejection,
                                    empty-store round-trip, restore-into-temp-store)

FenixKanbanTests/Services/Fizzy/
└── FizzySyncEngineBoardIsolationTests.swift  (~4 tests: one per sync entry-point)
```

### `BackupExporter` contract

```swift
@MainActor
final class BackupExporter {
    enum ExportError: Error, Equatable {
        case fileSystem(String)        // couldn't write
        case verificationFailed(String) // round-trip mismatch
    }

    /// Exports the entire CoreData store to a .fenixkanban-backup zip at
    /// the given URL. On success, immediately re-opens the zip into a
    /// temporary in-memory store, counts every entity, and asserts the
    /// counts match the live store. Throws `verificationFailed` if not.
    func exportVerified(
        to destination: URL,
        from controller: PersistenceController
    ) async throws -> ExportSummary
}

struct ExportSummary: Equatable {
    let path: URL
    let counts: [String: Int]   // entity name → row count
    let bytesWritten: Int64
    let verifiedAt: Date
}
```

The zip contains the three SQLite files (`store`, `store-wal`, `store-shm`)
plus a tiny `manifest.json` recording counts at export time. The verifier
re-derives counts from the loaded store and compares to manifest values.

### `BoardIsolation` test scenarios

Each test builds three local boards (3 columns each, 5 cards each = 15
cards per board, 45 total). Pairs board[0] with fizzy `FB1`. After running
the operation, asserts: `boards[1].cards.count == 15`,
`boards[2].cards.count == 15`, and that no `Card.fizzyID` was assigned on
non-paired boards.

| Test | Operation |
|------|-----------|
| `pushDoesNotTouchOtherBoards` | `syncFirst(mode: .pushLocalToFizzy)` |
| `replaceDoesNotTouchOtherBoards` | `syncFirst(mode: .replaceLocalWithFizzy)` with 7 remote cards |
| `mergeDoesNotTouchOtherBoards` | `syncFirst(mode: .mergeIfNoConflicts)` with mixed remote |
| `steadyDoesNotTouchOtherBoards` | `sync()` after pairing |

### Out of scope for 4c

- In-app restore UI. Documented as a manual file-replace process in
  `BackupSettingsView`'s footer copy.
- Backup encryption. The file is plaintext SQLite; user is responsible for
  storage hygiene (iCloud Files / external drive of their choice).
- Scheduled / automatic backups. Manual export only.
- Multi-version backup history. Each export overwrites the destination if
  the user picks an existing filename.

---

## Phase 5 — UI

### Goals

1. User can paste a Fizzy access token in Settings → Board Sync → Fizzy,
   verify it, and pair a local board with a Fizzy board.
2. User can manually trigger sync ("Sync Now") and see status.
3. User can sign out (clears token + pairing, keeps local cards).
4. 401 mid-session surfaces a re-auth banner inline; no other screens
   notify.
5. `FizzySyncProvider` conforms to `BoardSyncProvider` and is registered
   at app launch.
6. App is first pointed at real `fizzy.bluefenix.net` (manual UAT).

### Architecture

```
PluginRegistry.shared
  └── FizzySyncProvider (registered in FenixKanbanApp.init)
        └── wraps: FizzyClient, FizzyAuthState, FizzyBoardMapping,
                   FizzySyncEngine

SyncSettingsView (existing, lightly updated)
  └── NavigationLink → FizzyAuthView
        └── switches on computed phase + forceVerify override:
              forceVerify == true  → FizzyAuthVerifyView (manual re-auth)
              .unconfigured        → FizzyAuthVerifyView
              .unpaired            → FizzyAuthPairView
              .paired              → FizzyAuthStatusView
              .pairedNoToken       → FizzyAuthStatusView (with 401 banner)
```

`FizzyAuthView` is a thin parent that owns shared dependencies and computes
`phase` from `authState` + `mapping`. The three sub-views are independently
previewable and testable; each owns its own transient `@State` (entered
token, in-flight task, errors).

### New files

```
FenixKanban/Features/Sync/Fizzy/
├── FizzySyncProvider.swift              (~120 LOC)
├── FizzyAuthView.swift                  (~50 LOC — phase switch)
├── FizzyAuthVerifyView.swift            (~110 LOC)
├── FizzyAuthPairView.swift              (~180 LOC — three pickers + destructive UX)
└── FizzyAuthStatusView.swift            (~130 LOC — status hero + 401 banner)

FenixKanbanTests/Features/Sync/Fizzy/
└── FizzySyncProviderTests.swift         (~5 tests)
```

### Modified files

```
FenixKanban/Features/Sync/SyncSettingsView.swift  (badge + subtitle, remove
                                                   "no providers" empty state)
FenixKanban/FenixKanbanApp.swift                  (register FizzySyncProvider)
FenixKanban/Core/Services/Fizzy/FizzyError.swift  (add .requiresInteractiveAuth)
```

### `FizzySyncProvider` conformance

| Protocol member | Implementation |
|---|---|
| `providerName` | `"Fizzy"` |
| `iconName` | `"bolt.circle.fill"` (SF Symbol) |
| `isAuthenticated` | `authState.isConfigured` |
| `authenticate()` | Throws `FizzyError.requiresInteractiveAuth` — UI uses this signal to present `FizzyAuthView` |
| `signOut()` | `authState.clear()` + `mapping.clear()`. **No `Card` data touched.** |
| `fetchRemoteBoards()` | `client.get("/:account/boards", as: [FizzyBoard].self)`, mapped to `[RemoteBoard]` |
| `sync(boardId:remoteProjectId:)` | `engine.sync()` → maps `FizzySyncResult` to public `SyncResult` |
| `lastSyncDate(for:)` | `mapping.lastSyncAt` |

`FizzyError` gets a new case:

```swift
case requiresInteractiveAuth   // Throws when an automated authenticate() call
                                // can't proceed without user input (token paste).
```

### Phase computation

```swift
enum FizzyAuthPhase {
    case unconfigured       // no token in keychain
    case unpaired           // token present, no mapping
    case paired             // both
    case pairedNoToken      // mapping present but authState cleared (401 mid-session)
}

var phase: FizzyAuthPhase {
    let configured = authState.isConfigured
    let paired = mapping.isPaired
    return switch (configured, paired) {
        case (false, false): .unconfigured
        case (true, false):  .unpaired
        case (true, true):   .paired
        case (false, true):  .pairedNoToken
    }
}
```

`.pairedNoToken` is the 401-mid-session case. `FizzyAuthView` routes it to
`FizzyAuthStatusView` so the 401 banner shows over the same surface the
user was last on, with "Re-enter Token" as the recovery CTA.

Tapping "Re-enter Token" *cannot* simply clear mapping (we'd lose the
pairing). Instead, the parent owns a `@State var forceVerify: Bool = false`.
The CTA sets `forceVerify = true`, which overrides the phase-based switch
and renders `FizzyAuthVerifyView`. On successful re-verify,
`forceVerify` resets to `false` and phase recomputes — `.pairedNoToken`
becomes `.paired` (mapping was intact all along), so the user lands back
on the status view with sync restored.

### Data flow — verify

```
user enters token in FizzyAuthVerifyView
  → authState.setAccessToken(entered)
  → FizzyClient(baseURL: authState.baseURL, token: entered, slug: "")
       .get("/my/identity", as: FizzyIdentity.self)
  → on success:
      authState.setAccountSlug(identity.accounts.first.slug)
      parent recomputes phase → .unpaired → FizzyAuthPairView renders
  → on FizzyError.unauthorized:
      authState.clear() · view shows "Invalid token. Check it on Fizzy."
  → on FizzyError.network:
      view shows "Couldn't reach Fizzy" · token NOT cleared (user can retry)
```

### Data flow — pair

```
user picks (localBoard, fizzyBoard, mode) in FizzyAuthPairView
  → if mode == .replaceLocalWithFizzy: show .alert
       "Delete N cards on '<local>'?" with destructive "Delete & Replace"
       cancel button. User must confirm before sync runs.
  → mapping.setPairing(localBoardID: picked.id, fizzyBoardID: picked.fizzyID)
  → engine.syncFirst(mode: pickedMode)
  → on success: phase recomputes → .paired
  → on FizzyError.unauthorized: engine cleared authState; phase →
       .pairedNoToken (banner renders on status view)
  → on other error: in-line error row; mapping stays so user can retry
```

### Data flow — sync now

```
user taps Sync Now in FizzyAuthStatusView
  → engine.sync()
  → on success: refresh lastSyncAt display
  → on FizzyError.unauthorized: engine cleared authState; view phase
       recomputes → .pairedNoToken → 401 banner renders inline above
       status hero ("Re-enter Fizzy access token"). User taps "Re-enter
       Token" → parent sets forceVerify=true → verify view renders.
  → on other: in-line error row, status hero still shown
```

### Data flow — sign out

```
user taps Sign Out (destructive row at bottom of status view)
  → confirmation alert: "Sign out of Fizzy? Local cards are kept."
  → on confirm:
      cancel any in-flight sync task
      authState.clear()
      mapping.clear()
      phase recomputes → .unconfigured → verify view
```

### Error surfaces

| Error path | Where surfaced | Recovery |
|---|---|---|
| `FizzyError.network` on Verify | `FizzyAuthVerifyView` inline row | Retry button. Token field stays populated. |
| `FizzyError.unauthorized` on Verify (wrong token) | `FizzyAuthVerifyView` inline row | `authState.clear()` so user can re-paste. |
| `fetchRemoteBoards` fails | `FizzyAuthPairView` `ContentUnavailableView` for error | "Try again" button reloads `.task`. |
| `syncFirst` fails non-401 | `FizzyAuthPairView` inline row | Mapping stays paired; user re-taps "Pair & Sync" (which now calls `sync()`, not `syncFirst`). *Plan will name this nuance.* |
| `sync()` returns 401 mid-session | `FizzyAuthStatusView` top-anchored yellow banner with "Re-enter Token" CTA | Engine has already cleared authState; tap CTA → phase recomputes → verify view. |
| `syncFirst` returns merge collisions | `FizzyAuthPairView` disclosure group at bottom | Informational only; user can re-run after resolving. |
| User signs out while sync in flight | `FizzyAuthStatusView` ignores in-flight result | Task is cancelled before `authState.clear()`. |
| User triggers Sync Now while one is running | "Sync Now" disabled during in-flight | Visible spinner; new tap impossible. |

### Testing — Phase 5

**Unit tests** (`FizzySyncProviderTests`, Swift Testing, `@MainActor`):

1. `providerNameMatchesSpec` — `"Fizzy"`.
2. `isAuthenticatedMirrorsAuthState` — set/clear authState, observe boolean.
3. `signOutClearsAuthAndMappingNoCards` — pre-load CoreData with cards on
   the paired board AND a non-paired board, call signOut, assert authState
   + mapping cleared, both boards' cards unchanged.
4. `fetchRemoteBoardsMapsDTOs` — MockURLProtocol returns FizzyBoard JSON,
   provider yields `[RemoteBoard]` with matching fields.
5. `syncTranslatesFizzySyncResultToPublicSyncResult` — mock the engine,
   assert field-by-field mapping.

**Manual UAT** (added to plan acceptance criteria):

1. Cold launch with no Fizzy setup → Settings → Board Sync → Fizzy row
   shows chevron only → tap → verify form → enter valid token →
   account name appears → board pickers materialize → pair with
   default mode (.push) → returns to status view, "Sync Now" enabled.
2. Edit a card title in FenixKanban → tap "Sync Now" → refresh
   fizzy.bluefenix.net in browser → title updated.
3. Edit a card title in Fizzy → tap "Sync Now" → local card title
   updated.
4. Toggle `golden` in Fizzy → "Sync Now" → local card's gold state matches.
5. Pick destructive `.replace` mode for a NEW pairing → tap "Pair & Sync"
   → confirmation alert with card count shows → confirm → local cards
   wiped + replaced with Fizzy's; other local boards' cards unchanged.
6. Revoke token in Fizzy admin → tap "Sync Now" → yellow banner appears
   inline above status → tap "Re-enter Token" → re-verify → banner clears
   on next sync.
7. Sign Out → mapping clears, authState clears, local cards retained →
   re-pair to same Fizzy board with `.merge` mode → orphan-claim re-binds
   cards by title+createdAt.

### Out of scope for Phase 5

- Polling timer (5-minute foreground poll while `scenePhase == .active`)
  → **Phase 6**.
- `CardView` cloud badges showing per-card sync state → **Phase 6**.
- Per-Card sync columns view (the original spec mentioned a debug surface)
  → not scheduled.
- Auto-registration with the system Shortcuts app for "Sync now" → defer
  pending Phase 6's AppIntents work.

---

## UI-SPEC — Locked Design Decisions

Visual contract for Phase 5's implementation. Mockups in
`.planning/sketches/001-004/`. Winning variants listed under each surface;
behavior beyond what the sketch shows is also locked here.

### Tokens

Visual tokens map to native iOS 26 / Liquid Glass conventions —
**SwiftUI handles the actual rendering**, the sketch CSS is approximate.

- **Background:** system grouped background (`.systemGroupedBackground` /
  `.windowBackgroundColor`). **Do not** override with custom `.background`
  modifiers — that suppresses Liquid Glass (per `CLAUDE.md`).
- **Surface:** standard Form sections / GroupBox; system materials apply
  automatically when running under iOS 26 / macOS 26 SDKs.
- **Tint:** `.tint` defaults to the app's accent. Destructive uses
  `.foregroundStyle(.red)` / `Button(role: .destructive)`.
- **Typography:** Dynamic Type, default styles. Section headers use
  `.font(.subheadline).textCase(.uppercase)`.
- **Spacing:** standard iOS 8pt grid via `.padding()` defaults; do not
  hand-pick spacing values.

### Surface 1 — `SyncSettingsView` row (sketch 001, variant **C**)

The sketch demonstrates row variants across providers; in production the
only registered provider for Phase 5 is **Fizzy**, so the list shows a
single row. The "GitHub Projects" / "Fizzy (second account)" rows in the
sketch illustrate *future* state and the **need-action** variant of the
Fizzy row respectively.

```
┌──────────────────────────────────────────────────────────┐
│ [⚡︎]  Fizzy                                              │
│       Synced 2 min ago                       (✓)  ›      │  ← healthy
└──────────────────────────────────────────────────────────┘

(same row, 401 state)
┌──────────────────────────────────────────────────────────┐
│ [⚡︎]  Fizzy                                              │
│       Tap to re-enter token                  (!)  ›      │  ← needs action
└──────────────────────────────────────────────────────────┘

(same row, not-set-up state)
┌──────────────────────────────────────────────────────────┐
│ [⚡︎]  Fizzy                                              │
│       Not set up                                  ›      │
└──────────────────────────────────────────────────────────┘
```

- Trailing **status badge** (22pt circle): `.green` checkmark when
  `provider.isAuthenticated && mapping.isPaired && !banner401`; `.orange`
  exclamation when `mapping.isPaired && !authState.isConfigured` (401
  state); no badge when `!isAuthenticated`.
- Subtitle uses `provider.statusSummary` (new computed string on
  `FizzySyncProvider`): "Synced N ago" / "Tap to re-enter token" / "Not set up".
- Disclosure chevron always present (it's a `NavigationLink`).
- Tap → push `FizzyAuthView`.
- **Empty state** (no providers registered) is removed. `FizzySyncProvider`
  is always registered at app launch.

### Surface 2 — `FizzyAuthVerifyView` (sketch 002, variant **A**)

```
‹ Board Sync                    Fizzy

  ACCESS TOKEN
  ┌────────────────────────────────────┐
  │ Paste your fizzy.bluefenix.net…    │
  └────────────────────────────────────┘
  Create or copy a token at fizzy.bluefenix.net/me/access.

  ↑ optional inline error/success row

  ┌────────────────────────────────────┐
  │       Verify Connection            │  ← primary, full-width
  └────────────────────────────────────┘
```

- iOS grouped `Form` with one `Section`, header `"Access Token"`, footer
  containing the help text with a tappable link (`Link(_:destination:)`).
- Token `TextField` with `.textContentType(.password)` so iOS suppresses
  autofill suggestions; `.textInputAutocapitalization(.never)`;
  `.disableAutocorrection(true)`; `.monospaced()`.
- Footer button area sits *outside* the Form, padding `16pt` horizontal
  and `24pt` top.
- Button is `.borderedProminent`, full-width via `.frame(maxWidth: .infinity)`,
  disabled when token is empty or `isVerifying`. Spinner inline when
  verifying (`ProgressView()` + label).
- Success row: short green confirmation ("Verified — connected as
  <name>"), shown for ~600ms then phase transitions to `.unpaired` (the
  view tree swaps to `FizzyAuthPairView`).
- Error row: red, single line. `keyboardShortcut(.return, modifiers: [])`
  on the button so pressing Enter triggers verify.

### Surface 3 — `FizzyAuthPairView` (sketch 003, variant **D-synth**)

```
‹ Board Sync                    Fizzy            Cancel

  ┌──────────────────────────────────────────────────────┐
  │ 💾  Export a backup first                            │
  │     Recommended before your first sync.              │
  │                                  [Open Backup]    ×  │
  └──────────────────────────────────────────────────────┘

  ACCOUNT
  ┌──────────────────────────────────────────────────────┐
  │ Chris Pelatari                                       │
  │ 897362094 · chris@pelatari.com                       │
  └──────────────────────────────────────────────────────┘

  LOCAL BOARD
  ┌──────────────────────────────────────────────────────┐
  │ Board                              Roadmap (47)  ›   │
  └──────────────────────────────────────────────────────┘
  Only this board syncs. Other local boards stay untouched.

  FIZZY BOARD
  ┌──────────────────────────────────────────────────────┐
  │ Board                          Public Roadmap   ›   │
  └──────────────────────────────────────────────────────┘

  FIRST SYNC
  ┌──────────────────────────────────────────────────────┐
  │  [ Push ]  [ Replace ]  [ Merge ]                    │
  └──────────────────────────────────────────────────────┘
  Push — upload every local card to Fizzy. Non-destructive.

  ↑ destructive warning materializes here when Replace picked

  ┌──────────────────────────────────────────────────────┐
  │           Pair & Sync                                │  (turns red →
  └──────────────────────────────────────────────────────┘     "Delete & Replace"
                                                                in Replace mode)
```

- **Backup banner** at top: dismissable. Dismissal stored in
  `UserDefaults` (`"fizzy.pair.backupBannerDismissed"`). Tap "Open Backup"
  navigates to `BackupSettingsView` (Phase 4c).
- **Account** row is read-only (sub-row from `authState.accountSlug` +
  identity cached at verify time).
- **Local Board** picker — `NavigationLink` to a `List` of all local
  boards fetched via `BoardRepository`. Subtitle on each row shows card
  count. Defaults to the first board if exactly one exists.
- **Fizzy Board** picker — `NavigationLink` to a `List` of remote boards
  fetched via `provider.fetchRemoteBoards()`. Loading / empty / error
  states via `ContentUnavailableView`.
- **First Sync** segmented control (`Picker(_:selection:).pickerStyle(.segmented)`).
  Default: `.pushLocalToFizzy`. Replace segment uses
  `.tint(.red)` (or matches the destructive warning treatment).
- **Mode help footer** updates per selection (3 strings, no string
  interpolation beyond card count).
- **Destructive warning** row appears under the mode picker only when
  `mode == .replaceLocalWithFizzy`. Red-tinted GroupBox-like card with
  warning icon, count of cards to be deleted, and "Confirm again on next
  tap" copy.
- **Primary button** is "Pair & Sync" (`.borderedProminent`, full-width)
  for `.push` / `.merge`. Transforms to **"Delete & Replace"**
  (`Button(role: .destructive)`) when `.replace` is selected.
- **Confirmation alert** (`.alert`) fires only for `.replace` mode on tap.
  Title: "Delete N cards on '<board>'?" Body explains the operation and
  irreversibility. Buttons: Cancel + "Delete & Replace" (destructive).
- **Cancel** in the nav bar dismisses the view back to SyncSettingsView
  without writing pairing.

### Surface 4 — `FizzyAuthStatusView` (sketch 004, variant **A**)

```
‹ Board Sync                    Fizzy

  ┌──────────────────────────────────────────────────────┐  ← banner-401
  │ ⚠  Re-enter Fizzy access token                       │     (only when
  │    Your token was revoked. Sync paused.              │     phase ==
  │                                  [Re-enter Token]    │     .pairedNoToken)
  └──────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │ [⚡︎]  Public Roadmap                                  │
  │       Paired with “Roadmap” · Connected              │
  │ ─────────────────────────────────────────────────────│
  │   LAST SYNC          CARDS SYNCED                    │
  │   2 min ago          47                              │
  └──────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │              Sync Now                                │  ← disabled
  └──────────────────────────────────────────────────────┘     when paused

  ┌──────────────────────────────────────────────────────┐
  │ Sign Out                                             │  ← destructive row
  │ Clears token + pairing. Local cards are kept.        │
  └──────────────────────────────────────────────────────┘
```

- **Status hero** is a GroupBox-like surface with the Fizzy icon, board
  name (remote), pair info subtitle ("Paired with '<localBoard>' · Connected"),
  and two-column metrics (Last Sync via `RelativeDateTimeFormatter` from
  `mapping.lastSyncAt`, Cards Synced derived live — count of `Card`s on
  the paired local board with non-nil `fizzyID`). No new persisted state
  is needed for the metrics.
- **Sync Now** button — `.borderedProminent`, full-width. Spinner +
  "Syncing…" label during in-flight. Disabled and reads "Sync Paused"
  when `phase == .pairedNoToken`.
- **Sign Out** row in a Form-style section at the bottom; `Button(role:
  .destructive)`. Tap → confirmation alert "Sign out of Fizzy? Local cards
  are kept." → Cancel / Sign Out (destructive).
- **401 banner** appears *above* the status hero when `phase ==
  .pairedNoToken`. Yellow material (system `.yellow.opacity(0.16)` over
  Liquid Glass). Tap "Re-enter Token" → phase recomputes to `.unconfigured`
  → verify view renders.

### Interaction notes — locked

1. **All Form sections respect system Dynamic Type** — no fixed `.font(.system(size: ...))`.
2. **All buttons** that perform network IO show a `ProgressView` inline
   during in-flight; the button is `.disabled(true)` until complete.
3. **All async operations** are wrapped in `Task { … }` and stored in
   an `@State var task: Task<Void, Never>?`. On view disappear, the
   task is cancelled.
4. **No custom `.background(...)` modifiers** on the root view of any
   surface — let Liquid Glass apply.
5. **All text strings** that show user-visible action verbs use sentence
   case ("Sync now", "Sign out") in copy but title case ("Sync Now",
   "Sign Out") on button labels per Apple HIG.

---

## Build sequence

1. **Phase 4c — Backup + Safety** (1 PR)
   - `BackupExporter` + `BackupSettingsView`
   - `BackupExporterTests` (4)
   - `FizzySyncEngineBoardIsolationTests` (4)
   - SyncSettings → Backup nav entry from Settings root
   - **Lands first; no Fizzy UI changes.**

2. **Phase 5 — Fizzy UI** (1 PR)
   - `FizzyError.requiresInteractiveAuth` case
   - `FizzySyncProvider` + registration in `FenixKanbanApp.init`
   - `FizzyAuthView` parent + 3 sub-views
   - `SyncSettingsView` row update + empty-state removal
   - `FizzySyncProviderTests` (5)
   - Manual UAT against real fizzy.bluefenix.net

## Success criteria

### Phase 4c

- [ ] `swift build` succeeds for iOS and macOS targets.
- [ ] 8 new tests pass (4 backup + 4 isolation); full suite green.
- [ ] Exporting a backup → verifier reports counts; opening the exported
      zip and re-reading entities yields the same counts.
- [ ] Corruption test: truncating an exported zip → verifier rejects.
- [ ] Isolation tests: each of the 4 sync entry-points proven not to
      touch boards[1] / boards[2] when only board[0] is paired.

### Phase 5

- [ ] `swift build` succeeds for iOS and macOS.
- [ ] 5 new tests pass; full suite green.
- [ ] Manual UAT items 1–7 in "Testing" all pass against real
      fizzy.bluefenix.net.
- [ ] Cold-launch with `authState == nil && mapping == nil` shows
      `.unconfigured` → verify form.
- [ ] Cold-launch with paired+configured state goes straight to status view.
- [ ] Cold-launch with paired+`!configured` (test by deleting Keychain
      entry only) goes to status view with 401 banner visible.
- [ ] No `.background(.systemBackground)` or `.background(.windowBackground)`
      modifier anywhere in the new Fizzy/Backup views (Liquid Glass).

---

## Risks & open questions

- **`BoardSyncProvider.authenticate()` throws** — the provider currently
  has to throw `FizzyError.requiresInteractiveAuth` to signal "go open
  FizzyAuthView." If a future provider (GitHub Projects) wants
  OAuth-via-system-browser, this signal won't fit; we may need a richer
  return type. Out of scope for now; documented as a known limitation.
- **`SyncResult` vs `FizzySyncResult`** — Phase 5 has to translate between
  these. Trivial mapping, but adds a small per-call cost; acceptable.
- **Backup file size** — for a user with thousands of cards the SQLite
  store could exceed 100MB. Exporter should stream rather than load
  the whole file in memory. Concrete strategy in the plan.
- **iCloud Backup pickup** — if a user signs in from another device after
  Sign Out, CloudKit will re-sync local Cards (with `fizzyID`s intact)
  but `authState`/`mapping` are local-only. The orphan-claim path handles
  the re-binding. Worth a note in `BackupSettingsView`'s footer copy.
