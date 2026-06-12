# Fizzy Phase 5 — UAT Handoff

**Saved:** 2026-05-26 03:35 CDT (early June 2026 resume planned)
**Branch:** `develop` (clean, ahead of `origin/develop` by 2 commits)
**Phase status:** code complete; UAT 3/7 passed, 4/7 paused on a discovered bug.

> **To resume:** read this file, then jump to the **Resume checklist** at the bottom.

---

## Where things stand

**Phase 5 (Fizzy sync UI) is functionally working** against the live `fizzy.bluefenix.net` server. UAT caught two real bugs already shipped:

| SHA       | Fix                                                                  | Caught by                                                      |
| --------- | -------------------------------------------------------------------- | -------------------------------------------------------------- |
| `8424677` | `FizzyClient` URL builder: strip leading `/` from `accountSlug`      | UAT Item 2 — board picker requested `https://1/boards`         |
| `4c33125` | `@MainActor` on `BoardSyncProvider` + `PluginRegistry`               | Swift 6 strict-concurrency warning on Xcode rebuild            |

UAT items **1, 2, 3 passed** (verify+pair, push title edit, pull title edit). Item **4** (pull golden-flag toggle) was queued up but not executed before pausing.

---

## The blocker — push duplicates

After running UAT items 1–3, the live Fizzy board ended up with **~40 cards, many duplicates**. This wasn't an item failure — it's a separate bug surfaced by repeated `Sync Now` taps.

**Hypothesis:** the push path is creating new remote cards on every sync instead of reconciling by remote ID. Either:

- (a) `Card.remoteID` isn't being set after the first POST → next sync sees an "unsynced local card" and POSTs again, or
- (b) `Card.remoteID` is set, but the engine's "what needs pushing" predicate ignores it, or
- (c) something else in the steady-state loop double-counts.

**Where to look:**
- `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift` — the push path and `lastPushAt`/etag handling
- `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift` — existing push tests probably test single-sync, not double-sync

**Suggested regression test before fix:**
> Run `engine.sync()` twice with no local mutations between. Assert that the mock server received N POSTs on the first call and 0 POSTs on the second.

Existing engine tests use a mock server; this should be straightforward to add as the Red phase.

---

## Before resuming UAT — create a test board pair

Items 5 (`.replace`) and 7 (Sign Out + re-pair) are destructive. The push-duplicates repro will also mutate the remote. **Do not run any of this against the currently-paired real board** — it has work being tracked in FenixKanban.

1. On `fizzy.bluefenix.net`: create a fresh board, e.g. **"FenixKanban UAT Test"**, with 2–3 columns and 3–4 cards.
2. In FenixKanban: tap **+** in the Boards list to create a matching empty local board with the same column shape.
3. Settings → Board Sync → Fizzy → **Sign Out** (this clears the current real-board pairing; local cards are kept by design — orphan-claim re-binds by `title + createdAt` if you ever re-pair to the real board).
4. Re-pair to the new UAT Test boards using `.pushLocalToFizzy`.
5. Now you have a disposable pairing for the rest of UAT and the duplicates investigation.

After the test board exists, the polluted ~40-card Fizzy board can be manually cleaned up (or just deleted + recreated as the UAT board if you don't need its current content).

---

## Remaining UAT (against the test board pair)

| # | Item                                                          | Status                                                           |
| - | ------------------------------------------------------------- | ---------------------------------------------------------------- |
| 4 | Toggle `golden` flag in Fizzy → syncFirst replaceLocal → `isGolden == true` | **Automated** — `LiveUATTests/LiveUATPullGoldenTests` (PASS, 2026-06-12) |
| 5 | First-sync mode `.replace` with confirmation alert            | **Automated** — `LivePlaygroundRestoreTests` (restore E2E suite) |
| 6 | Garbage token → `sync()` throws `.unauthorized` → authState cleared | **Automated** — `LiveUATTests/LiveUAT401RecoveryTests` (PASS, 2026-06-12) |
| 7 | Sign Out (board-mapping clear) → re-pair → `mergeIfNoConflicts` → zero remote creates | **Automated** — `LiveUATTests/LiveUATRePairMergeTests` (suite written 2026-06-12; requires `FIZZY_ALLOW_MUTATION=1`) |

Full UAT details: `docs/superpowers/plans/2026-05-26-fizzy-phase-5-ui.md`, Manual UAT section.

---

## Open work parked for after Phase 5 ships

### Phase 6 polish (small, mostly UI)
- Form scroll bug in Settings integrations UI
- Backup error UX
- Backup filename collision
- Foreground polling timer (5-min while `scenePhase == .active`)
- CardView cloud badges
- Phase 4c reviewer follow-ups: `BackupExporter` off-main-actor, `BackupDocument: Sendable`, Data section split, schema-name constant

### Phase 7 — multi-board sync (real feature)
Surfaced during UAT when noticing 7 local boards but only one allowed pairing. Singleton design in `FizzyBoardMapping` is a real limit on usefulness.

Sketch:
- `FizzyBoardMapping` → list/dict of `(localBoardID, fizzyBoardID, etag, lastSyncAt)` keyed by local board
- `FizzyAuthStatusView` → list of paired boards w/ per-row Sync Now
- `FizzyAuthPairView` → "Pair another board" entry point on top of the existing pickers
- `FizzySyncEngine` → `sync(localBoardID:)` or iterate-all
- Eventually: per-board sync history / errors

### Backup needs revisiting (user flag)
Phase 4c shipped export. Things still untested or unresolved:
- Round-trip restore (export → wipe → restore → verify equality)
- Three Phase 6 backup polish items listed above
- Any new backup hardening surfaced by the upcoming restore test

---

## Lessons baked in

- **Fizzy API quirk:** `/my/identity` returns `slug` with a leading `/` (e.g. `"/897362094"`). Fixture `FenixKanbanTests/Fixtures/fizzy/identity.json` captures this; all FizzyClient tests prior to `8424677` passed `accountSlug: "ACCT"` — sanitized away the real shape, never caught the URL-builder bug. **At least one URL-construction test should consume the fixture's slug verbatim.**
- **TDD discipline held:** both fixes shipped with failing-test-first; iOS 219/219 + macOS clean preserved through both.
- **Single-pairing is a design choice, not an oversight.** Phase 5 was explicitly scoped that way — multi-board is Phase 7, not a Phase 5 bug.

---

## Resume checklist

When you next type "pick up from the handoff":

- [ ] Read this file + `.planning/HANDOFF.json`
- [ ] `git status` clean, `git log --oneline -5` confirms `4c33125` is the tip (or whatever you've added)
- [ ] Create test board pair per "Before resuming UAT" above
- [ ] Write the double-sync regression test (Red)
- [ ] Trace and fix `BUG-push-duplicates` (Green)
- [ ] Refactor + verify 220+/220+ tests
- [ ] Resume UAT from Item 4
- [ ] Items 4 → 5 → 6 → 7
- [ ] Ship Phase 5 (PR body skeleton in the plan file)
- [ ] Plan Phase 6 (polish) or Phase 7 (multi-board), depending on priority

---

## Files touched this session

```
M  FenixKanban/Core/Services/Fizzy/FizzyClient.swift
M  FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift
M  FenixKanban/Core/Plugins/BoardSyncProvider.swift
M  FenixKanban/Core/Plugins/PluginRegistry.swift
M  TDD_IMPLEMENTATION_STATUS.md
A  .planning/HANDOFF.json
A  .planning/HANDOFF.md
```
