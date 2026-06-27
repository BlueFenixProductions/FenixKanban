# Per-Board Fizzy Sync in the Board Menu — Design

**Date:** 2026-06-26
**Branch:** `feat/board-menu-fizzy-sync` (off `develop` @ `4a6a7ba`)
**Issue:** follow-on to #18 (multi-board pairing)

## Problem

Per-board Fizzy sync control already exists end-to-end — each `FizzyBoardPairing`
carries its own `syncEnabled` flag, and the scheduler (`FizzySyncProvider.orderedBoardsToSync()`)
already syncs each enabled board independently via round-robin. But the *controls*
are buried in Settings → Board Sync → **Manage Boards**, reachable only by a swipe
or long-press on a row. From a user's seat the sync setting reads as app-wide.

**Goal:** surface Fizzy sync as a per-board action where the user actually is —
open a board, tap the `···` toolbar menu, and manage that board's Fizzy sync inline.

## What already exists (no changes needed in the sync layer)

`FizzySyncProvider` exposes a complete per-board API, already used by
`FizzyBoardBrowserViewModel`:

- `setSyncEnabled(localBoardID:_:)` — pause/resume
- `unpair(localBoardID:)`
- `sync(boardId:remoteProjectId:) async throws` — sync now
- `createRemoteTwin(localBoardID:name:) async throws`
- `linkExisting(localBoardID:fizzyBoardID:fizzyBoardName:) async throws` — returns merge collisions
- `fetchRemoteBoards() async throws -> [RemoteBoard]`
- `boardPairingStoreRef.pairing(forLocal:) -> FizzyBoardPairing?` — current pairing (name, `syncEnabled`, `lastSyncAt`)
- `isAuthenticated` / `authStateRef.isConfigured` — token state

`BoardView` already grabs the provider and sets `currentBoardID = board.id` on
appear, and already computes `boardIsPaired` for the notification bell.

## Decisions

1. **Full lifecycle inline**, menu adapts to board state (3 states below).
2. **No-token state → present the setup flow as a sheet** (`FizzyAuthView`)
   directly from the board. This is a deliberate refinement of "deep-link to
   Settings": the app shell is a `NavigationSplitView` with Settings as its own
   sheet/stack, so cross-hierarchy deep-linking is fragile. An inline setup
   sheet reaches the same end state robustly.
3. **Approach A** — a small board-scoped view model that derives state
   synchronously from local stores and delegates every action to the provider.
   No sync logic is duplicated.

## Architecture (Approach A)

### New: `BoardFizzySyncModel`
`FenixKanban/Features/Board/BoardFizzySyncModel.swift` — `@MainActor @Observable`,
constructed with `(provider: FizzySyncProvider, boardID: UUID, boardName: String)`.
Kept separate from `BoardViewModel` (which owns columns/cards) so each unit stays
single-purpose.

State is a pure derivation from local stores — no network on the hot path:

```swift
enum State: Equatable {
    case notConfigured                              // no token
    case unpaired                                   // token present, no pairing for this board
    case paired(enabled: Bool, lastSyncAt: Date?)   // pairing exists
}

static func derive(isConfigured: Bool, pairing: FizzyBoardPairing?) -> State
// !isConfigured                       -> .notConfigured
// isConfigured && pairing == nil      -> .unpaired
// isConfigured && pairing != nil      -> .paired(enabled: pairing.syncEnabled,
//                                                 lastSyncAt: pairing.lastSyncAt)
```

A computed `var state: State` reads `provider.authStateRef.isConfigured` and
`provider.boardPairingStoreRef.pairing(forLocal: boardID)` and calls `derive`.

Actions (thin delegations; async ones catch and set `actionError`):

| Method | Delegates to |
|--------|--------------|
| `toggleSync()` | `setSyncEnabled(localBoardID: boardID, !enabled)` |
| `syncNow() async` | `sync(boardId: boardID, remoteProjectId: pairing.fizzyBoardID)` |
| `unpair()` | `unpair(localBoardID: boardID)` |
| `createOnFizzy() async` | `createRemoteTwin(localBoardID: boardID, name: boardName)` |
| `linkExisting(toFizzyBoardID:fizzyBoardName:) async` | `linkExisting(...)`; captures returned collisions |
| `loadUnpairedRemoteBoards() async throws -> [RemoteBoard]` | `fetchRemoteBoards()` filtered to boards with no pairing |

Published surface for the view: `actionError: String?`, `lastLinkCollisions: [String]?`.

### `BoardView` changes
`FenixKanban/Features/Board/BoardView.swift`

- Add a "Fizzy Sync" section to the **existing** primary-action `Menu`
  (after a `Divider` below "Show Closed Cards"), rendering per `state`:
  - **notConfigured** → `Button "Set up Fizzy Sync…"` → `showFizzySetup = true`
  - **unpaired** → `Button "Create on Fizzy"` → `createOnFizzy()`;
    `Button "Link to Fizzy Board…"` → load candidates then `showLinkSheet = true`
  - **paired(enabled, _)** → `Toggle "Fizzy Sync"` (on = syncing) → `toggleSync()`;
    `Button "Sync Now"` → `syncNow()`; `Button "Unpair…"` (`role: .destructive`) → `pendingUnpair = true`
- New `@State`: the `BoardFizzySyncModel`, `showFizzySetup`, `showLinkSheet`,
  `linkCandidates: [RemoteBoard]`, `pendingUnpair`, and a `fizzyRefresh: UUID`.
- New presentations:
  - `.sheet($showFizzySetup) { NavigationStack { FizzyAuthView(provider:) } }`
  - `.sheet($showLinkSheet) { LinkBoardSheet(localBoardName:, candidates: linkCandidates, onLink:, onCancel:) }`
  - `.confirmationDialog` for unpair: "Unpair this board?" / "Stops syncing this
    board. Your local cards are kept." (mirrors the browser's wording)
  - `.alert` for `actionError` ("Sync problem") and `lastLinkCollisions`
    ("Merged with collisions") — same patterns as `FizzyBoardBrowserView`.

### Refactor: extract `LinkBoardSheet`
Move `LinkBoardSheet` out of `FizzyBoardBrowserView.swift` (where it is a
`private struct`) into `FenixKanban/Features/Sync/Fizzy/LinkBoardSheet.swift` and
make it `internal`, so both the browser and the board menu share one
implementation. No behavior change.

## Data flow & refresh

- The menu reads `model.state` synchronously on each render.
- After any action, bump `fizzyRefresh = UUID()` on `BoardView` so the toolbar
  re-evaluates pairing state (mirrors the existing `FizzyAuthView.refreshTrigger`
  pattern — the pairing store is not itself observable).
- The "Link to Fizzy Board…" path loads candidates asynchronously on tap, then
  presents the sheet; a fetch failure routes to the `actionError` alert.

## Error handling

- All async provider calls are wrapped; thrown errors set `actionError`
  (surfaced via `.alert`).
- `linkExisting` returns merge collisions; non-empty collisions populate
  `lastLinkCollisions` and surface the "Merged with collisions" alert.
- The unpair confirmation is the only destructive guard; everything else is
  reversible.

## Scope / YAGNI

- **Excluded:** "Add to FenixKanban" (remote-only rows) — that is a
  browser-only concept; from a board the local board already exists.
- **Untouched:** the sync engine, scheduler, pairing stores, the existing
  `boardIsPaired` notification-bell logic, and Settings → Manage Boards (this is
  an *additional* entry point, not a replacement).

## Testing

- Pure unit tests for `BoardFizzySyncModel.derive(isConfigured:pairing:)` across
  all three states (incl. `paired` reflecting `syncEnabled` / `lastSyncAt`).
- Action-wiring tests against a spy/fake provider, following the existing
  `FizzyBoardBrowserViewModel` test harness: `toggleSync` negates the flag;
  `syncNow` passes the pairing's `fizzyBoardID`; `unpair`/`createOnFizzy`/
  `linkExisting` delegate with the right arguments; a thrown error populates
  `actionError`.

## Files

- **Create:** `FenixKanban/Features/Board/BoardFizzySyncModel.swift`
- **Create:** `FenixKanban/Features/Sync/Fizzy/LinkBoardSheet.swift` (extracted)
- **Modify:** `FenixKanban/Features/Board/BoardView.swift` (menu section + presentations)
- **Modify:** `FenixKanban/Features/Sync/Fizzy/FizzyBoardBrowserView.swift` (remove the inlined `LinkBoardSheet`)
- **Create:** `FenixKanbanTests/Features/Board/BoardFizzySyncModelTests.swift`
  (sibling convention: the existing VM tests live under `FenixKanbanTests/Features/Sync/Fizzy/`)
