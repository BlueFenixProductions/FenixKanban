# Multi-board pairing (Phase 7) — design

**Issue:** #18 — Multi-board pairing: board browser + per-board sync
**Date:** 2026-06-26
**Status:** Approved design, ready for implementation planning

## Goal

Mirror *every* board between FenixKanban (FK) and fizzy, in both directions.
Replace the brittle single-board, manual-ID pairing with a board browser that
discovers fizzy boards, reconciles them against local boards, and syncs N pairs
independently.

The sync engine internals are already board-parameterized
(`steadyStateSync(localBoard:fizzyBoardID:)`, the three `syncFirst*` methods).
The single-board assumption is concentrated in three places: the singleton
`FizzyBoardMapping`, the public guards in `FizzySyncEngine.sync()` /
`syncFirst(mode:)`, and the single-pair UI (`FizzyAuthStatusView` /
`FizzyAuthPairView`). `FizzyCardPairingStore` is already board-agnostic (keyed
globally by card UUID) and needs no change.

## Decisions (locked during brainstorming)

| Fork | Decision |
|------|----------|
| Where pairing records live | **Device-local** sidecar store, mirroring `FizzyCardPairingStore`. No CloudKit — consistent with the A′ work (#21/#22) that pulled pairing out of CloudKit because it duplicates on multi-device merges. |
| Board browser model | **Unified reconciliation list** — one list merging both sides (local + remote) by pairing, with inline per-row state and actions. |
| Sync concurrency | **Serial round-robin** — one board at a time, frontmost/visible board first, then rotation. Preserves the `isSyncing` reentrancy guard and the duplicate-card protections. |
| Browser placement | Settings **and** onboarding, one shared component (Captain ruling 2026-06-10). |
| Existing pairing migration | Silent auto-migrate the legacy singleton to row 1 (Captain ruling). |
| Create-remote-twin | Folded into this phase — wires the UI-less `FizzyClient.createBoard` (Captain ruling 2026-06-11). |
| First-sync experimentation | Steered to the **Sandbox board** (low stakes) before real boards. |
| Implementation strategy | **Approach A** — core-first in 3 sub-phases (7a headless core → 7b browser UI → 7c create/pull/link flows). |

## Phase 7a — Core (headless)

No new UI. The existing single-pair views keep working off row 1, so the risky
data-model + engine/provider/scheduler refactor lands behind tests with zero UX
regression.

### `FizzyBoardPairingStore` (new, device-local)

Replaces the singleton `FizzyBoardMapping`. JSON sidecar in Application Support,
injectable for tests (tests never touch the real sidecar), **not** in the
CloudKit set — same pattern as `FizzyCardPairingStore`.

```
BoardPairing {
  localBoardID: UUID        // FK Board
  fizzyBoardID: String      // opaque fizzy id
  fizzyBoardName: String?   // cached for display when offline
  lastSyncAt: Date?
  etag: String?             // reserved; per-board conditional pulls
  syncEnabled: Bool         // pause/resume per board (default true)
}
```

API: `pairings`, `pairing(forLocal:)`, `pairing(forFizzy:)`, `upsert(_:)`,
`setLastSync(localBoardID:_:)`, `setSyncEnabled(localBoardID:_:)`,
`remove(localBoardID:)`, `clearAll()`.

### Migration (silent, one-time, idempotent)

On first store load, if legacy `FizzyBoardMapping` `UserDefaults` keys exist:
fold them into a single `BoardPairing` (row 1), carry over `lastSyncAt`, then
delete the legacy keys. Guarded by a stored "migrated" flag so it runs once.
The new row is written **before** the legacy keys are deleted, so a crash
mid-migration never loses the pairing. Fresh install with no legacy keys = no-op.

### `FizzySyncEngine` — guard refactor only

The internal `steadyStateSync` / `syncFirst*` already take explicit board
params. Change is confined to the public guards:

- `sync()` → `sync(localBoardID:)`
- `syncFirst(mode:)` → `syncFirst(localBoardID:mode:)`

They look the board up in the new store instead of the singleton, and write
`lastSync` to that board's row. `isSyncing` stays per-instance (one engine per
board).

### `FizzySyncProvider` — per-board routing

Holds the new store. `BoardSyncProvider.sync(boardId:remoteProjectId:)` params
become *used* (route to the matching pairing) rather than ignored.
`lastSyncDate(for:)` returns that board's row. `isPaired` → "any pairing
exists." `makeEngine(for:)` builds a per-board engine. Adds orchestration entry
points used in 7b/7c: `pair`, `unpair`, `createRemoteTwin`, `pullRemoteBoard`,
`linkExisting`.

### Multi-board scheduler — serial round-robin

The `SyncTriggering` tick iterates `syncEnabled` pairings one at a time,
frontmost board first then rotation. "Frontmost" is reported by the app:
`BoardView` sets a `currentBoardID` on the provider when it appears. One engine
active at a time preserves the reentrancy / duplicate-card protections.

## Phase 7b — Unified board browser

A new `FizzyBoardBrowserView`, shared verbatim by Settings and onboarding (first
launch with no pairings routes into it). Fetches `GET /boards` (remote) and the
local `Board` set, then reconciles by the pairing store into one list.

```
┌─ Fizzy Boards ───────────────────────────────┐
│  Synced                                       │
│  ● Sandbox             synced 10:42   [⇄] ⋯  │  ← paired, enabled (toggle on)
│  ● Roadmap             synced 09:15   [⇄] ⋯  │     ⋯ = pause / unpair / Sync Now
│  ◌ Archive (paused)    —              [  ] ⋯  │  ← paired, sync disabled (dimmed)
│  ⟳ Sprint 12           syncing…              │  ← in progress (spinner)
│  ⚠ Bugs                error · tap to view    │  ← last sync errored
│                                               │
│  Local only                                   │
│  □ Personal            (not on fizzy)  [Create on fizzy]
│                                               │
│  On fizzy only                                │
│  □ Design Review       (not in FK)     [Add to FK]
└───────────────────────────────────────────────┘
```

**Reconciliation rule (the join):** each pairing → a paired row (resolve its
local `Board` + remote board); each local `Board` with no pairing → *Local
only*; each remote board with no pairing → *On fizzy only*.

**Per-row actions:** sync toggle (flips `syncEnabled`), `Sync Now` (one-board
`provider.sync`), pause, unpair (clears the pairing row; never touches `Card`
data — existing `changePairing` contract; re-pairing re-binds via orphan-claim).
Error rows expand to the message.

**State source:** rows are a pure projection of the pairing store plus a
per-board sync-activity map (reusing the Phase 6 `SyncActivityState` shape,
now keyed by board). No pairing state lives in the view, so it can't drift.

## Phase 7c — Create / Pull / Link flows

Three ways a pairing is created, each auto-selecting the existing first-sync mode:

1. **Create on fizzy** (local-only row → remote twin): `FizzyClient.createBoard`
   → upsert pairing → first-sync **pushLocalToFizzy** (local is source of truth,
   remote starts empty). Low risk.
2. **Add to FK** (remote-only row → local twin): create local `Board` from the
   remote name → upsert pairing → first-sync **replaceLocalWithFizzy** (remote
   is source of truth, local was just created empty). Low risk.
3. **Link existing ↔ existing** (both sides have content): a "Pair to existing
   fizzy board…" action on a *Local only* row opens a picker of unpaired remote
   boards → first-sync **mergeIfNoConflicts**. This is the riskiest path (it
   surfaces the conflict store), so it gets a confirm sheet and is steered to the
   **Sandbox board** for experimentation before real boards.

Paths 1 and 2 need no mode picker — the chosen action *is* the mode. Only path 3
(merge) warns.

## Testing

- **7a:** pairing-store CRUD + idempotent migration; engine guard routes board
  A's sync to A's cards only (two-pairing fixture); provider per-board routing;
  scheduler serial round-robin order (frontmost-first) via injected
  `currentBoardID`; `isSyncing` still blocks reentrancy. Headless,
  `MockURLProtocol`.
- **7b:** reconciliation join yields the correct row state for each of the 4
  cases (paired / paused / local-only / remote-only); toggle / pause / unpair
  mutate the store and never touch `Card` data; rows are a pure projection.
- **7c:** create-twin (pushLocal), add-to-FK (replaceLocal), link-existing
  (merge) each pair + run the correct first-sync mode; merge path routes
  conflicts to the conflict store.

## Out of scope (YAGNI)

- Board-pairing records syncing across devices — chosen device-local; no
  CloudKit work here.
- Per-board sync history/timeline (HANDOFF "eventually") — last-sync + error is
  enough for v1.
- Parallel sync — serial round-robin only.
- Offline comment queueing — tracked separately as #59.
