# Fizzy API Integration — Design

**Date:** 2026-05-25
**Status:** Draft (awaiting user review)
**Author:** Chris Pelatari (with Claude)

## Problem

FenixKanban has a `BoardSyncProvider` plugin protocol at `FenixKanban/Core/Plugins/BoardSyncProvider.swift` and a `SyncSettingsView` shell, but no concrete sync providers. The user runs a self-hosted Fizzy instance (37signals' open-source Kanban app, fork of fizzy.do) at `https://fizzy.bluefenix.net` and wants FenixKanban to two-way sync with it. A personal access token named `claude-dev` is already registered there.

## Goal

Two-way sync between one FenixKanban `Board` and one Fizzy board, covering the five core fields users edit day-to-day: title, description, column (workflow stage), tags (= labels), and the `golden` flag. Manual "Sync now" button + 5-minute foreground polling timer. Last-write-wins on conflict. Built as the first concrete `BoardSyncProvider` plugin so the architecture proves out.

## Non-goals

- Multi-board pairing (one local board ↔ one Fizzy board for MVP).
- Comments, reactions, pins, subscriptions, assignees, attachments, subtasks (Fizzy "steps") — these stay local-only or remote-only.
- Fizzy lifecycle states beyond column (`not_now`, `closed`, `published`/`draft`, `stream`).
- Due dates — FenixKanban has them, Fizzy doesn't expose an equivalent.
- Webhook listener — FenixKanban polls; Fizzy doesn't push.
- BGTask-based background sync — foreground only.
- Field-level conflict resolution or merge UI — last-write-wins at the card level.
- Magic-link auth flow — personal access token only.
- Generic / App Store-ready integration — this is the user's personal Fizzy instance with a hand-issued token.
- Activities-stream-driven incremental sync — recorded as a future optimization, not in MVP.

## Architecture

A new `FizzySyncProvider` conforms to the existing `BoardSyncProvider` protocol and is the only object that talks to fizzy.bluefenix.net. It registers itself in `PluginRegistry.shared` from `FenixKanbanApp.init()` *only* when a stored access token exists. With no token stored, no provider is registered and the rest of the app behaves identically to today.

The provider composes four smaller units:

- **`FizzyClient`** — `URLSession`-backed HTTP wrapper. Adds the `Authorization: Bearer …` header, manages `If-None-Match`/`ETag`, parses HTTP statuses into typed `FizzyError` values, retries transient failures with exponential backoff.
- **`FizzyDTOs`** — Codable structs matching the Fizzy JSON wire shapes for Board / Column / Card / Tag / Identity. Unsynced fields (assignees, comments, images) are still decoded so unexpected payloads don't crash; we just don't persist them.
- **`FizzySyncEngine`** — the diff/apply state machine. Pure logic — accepts a `FizzyClient` (real or mock) and a CoreData context. Produces `SyncResult`.
- **`FizzyBoardMapping`** — UserDefaults wrapper for `{ localBoardID, fizzyBoardID, lastSyncAt }` and the "is paired" predicate.

Each unit is testable in isolation: the engine takes a mocked client; the client takes a mocked URLProtocol.

## File structure

**New:**
- `FenixKanban/Core/Services/Fizzy/FizzyClient.swift`
- `FenixKanban/Core/Services/Fizzy/FizzyDTOs.swift`
- `FenixKanban/Core/Services/Fizzy/FizzySyncProvider.swift`
- `FenixKanban/Core/Services/Fizzy/FizzySyncEngine.swift`
- `FenixKanban/Core/Services/Fizzy/FizzyBoardMapping.swift`
- `FenixKanban/Core/Services/Fizzy/FizzyAuthState.swift` — Keychain wrapper for `accessToken`/`accountSlug`/`baseURL`
- `FenixKanban/Core/Services/Fizzy/FizzyError.swift`
- `FenixKanban/Features/Sync/FizzyAuthView.swift`
- `FenixKanban/Core/Persistence/FenixKanban.xcdatamodeld/FenixKanban 3.xcdatamodel/` — new CoreData model version with three optional Card attributes
- `FenixKanbanTests/Services/Fizzy/FizzyClientTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzyDTOTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzySyncEngineTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzySyncProviderTests.swift`
- `FenixKanbanTests/Services/Fizzy/FizzyBoardMappingTests.swift`
- `FenixKanbanTests/Fixtures/fizzy/board.json`, `cards.json`, `identity.json`, `columns.json` — recorded sample responses
- `FenixKanbanTests/Fixtures/fizzy/README.md` — how to refresh fixtures from a live instance

**Modified:**
- `FenixKanban/FenixKanbanApp.swift` — register `FizzySyncProvider` at startup if token present
- `FenixKanban/Features/Sync/SyncSettingsView.swift` — always show a Fizzy row, route to `FizzyAuthView`
- `FenixKanban/Features/Card/CardView.swift` — add the small per-card cloud badge next to existing `GoldZoneChip` / `DueDateBadge`
- `TDD_IMPLEMENTATION_STATUS.md` — log per phase

## Data model

### Keychain (via existing `KeychainHelper`)

| Key | Value |
|---|---|
| `fizzy.accessToken` | Bearer token (the `claude-dev` PAT) |
| `fizzy.accountSlug` | The `:account_slug` segment used in every Fizzy URL (e.g. `897362094`) |
| `fizzy.baseURL` | Default `https://fizzy.bluefenix.net`; user-overridable (localhost dev, etc.) |

### UserDefaults (via `FizzyBoardMapping`)

| Key | Value |
|---|---|
| `fizzy.pairing.localBoardID` | UUID string of the paired local `Board` |
| `fizzy.pairing.fizzyBoardID` | Opaque Fizzy ID string (e.g. `03f5v9zkft4hj9qq0lsn9ohcm`) |
| `fizzy.pairing.lastSyncAt` | ISO8601 timestamp |

Singleton pairing for MVP. Multi-pair would migrate this to a `Board.fizzyBoardID: String?` CoreData attribute.

### CoreData (lightweight migration)

New `FenixKanban 3.xcdatamodel` adds three optional attributes on `Card`:

| Attribute | Type | Purpose |
|---|---|---|
| `fizzyID` | `String?` | Fizzy's opaque card ID; `nil` = local-only, needs push on next sync |
| `fizzyEtag` | `String?` | Last ETag seen for this card; sent on next GET for 304 short-circuit |
| `fizzyUpdatedAt` | `Date?` | Fizzy's `last_active_at` from the last successful fetch; the timestamp compared against local `updatedAt` for last-write-wins |

Lightweight migration is automatic (same pattern as the recently-shipped `isGolden` migration). Optional types are CloudKit-required, so this stays CloudKit-friendly.

## Field mapping

| Direction | Fizzy field | Local field | Notes |
|---|---|---|---|
| both | `card.title` | `Card.title` | Direct string |
| both | `card.description` | `Card.cardDescription` | Plain text only in MVP; Fizzy's `description_html` is ignored |
| both | `card.column.name` | `Card.column.name` | Match by **case-insensitive trimmed name**; auto-create local Column on pull, NOT remote on push |
| both | `card.tags` (`[String]`) | `Card.labels` → `Label.name` | Auto-create local `Label` with deterministic hash-based color on first sight; tag set follows card-level LWW |
| both | `card.golden` | `Card.isGolden` | Direct bool; named identically by happy accident |
| read-only decode | `card.assignees`, `card.image_url`, `card.has_attachments`, `card.last_active_at`, `card.created_at`, comments_count | (none) | Decoded so future schema changes don't crash; not persisted in MVP |
| read-only decode | column `not_now`, `closed`, `stream` | (none) | Fizzy lifecycle state ignored in MVP |
| not synced | due dates, comments, reactions, pins, attachments, subtasks, assignees | unchanged | Stays local-only or remote-only |

## Sync cycle

Triggered by manual button OR foreground 5-minute timer.

```
1. PAIRING CHECK
   If no { token, accountSlug, localBoardID, fizzyBoardID }, return early.

2. FETCH REMOTE STATE
   GET /:account/boards/:fizzyBoardID/columns
   GET /:account/boards/:fizzyBoardID/columns/:col/cards   (per column, with If-None-Match)
   Build { fizzyCardID → RemoteCard } map.

3. FETCH LOCAL STATE
   Read all Cards for the paired Board from CoreData.
   Build { fizzyID → Card } map.

4. DIFF
   For each remote card:
     match exists locally?         → UPDATE candidate (resolve by timestamp in step 5)
     no match locally?             → CREATE local Card
   For each local card with fizzyID:
     not in remote response?       → soft-delete locally (Fizzy removed it)
   For each local card with nil fizzyID:
                                   → POST to Fizzy, store returned fizzyID

5. APPLY (last-write-wins by timestamp)
   For each UPDATE candidate:
     remote.updatedAt > local.updatedAt → pull remote into local
     local.updatedAt  > remote.updatedAt → PATCH remote with local
     equal                              → no-op

6. PERSIST SYNC STATE
   Update fizzyEtag, fizzyUpdatedAt on each touched Card.
   Update fizzy.pairing.lastSyncAt.
   Return SyncResult { created, updated, deleted, errors }.
```

**Concurrency.** The whole cycle runs on a single `@MainActor`-isolated task. CoreData viewContext is main-thread; HTTP awaits happen between CoreData touches. No background contexts — matches how the rest of the app uses CoreData.

**Idempotence.** Every step is safe to retry. If the app dies mid-sync, the next run re-converges cleanly because state lives in CoreData + UserDefaults; in-flight nothing-yet is lost.

**Crash-after-POST recovery.** If we POST a new card and crash before saving the returned `fizzyID`, the next sync sees a duplicate (local `nil fizzyID` + remote with matching title). Diff step matches by **title equality + createdAt within ±60s**; if matched, claim the orphan and skip the re-POST. Imperfect but adequate — user can hand-merge if it goes wrong.

**Polling cadence.** `Timer.scheduledTimer` started in `FizzySyncProvider.register()` when token+slug present, fires every 5 minutes while `scenePhase == .active`. Stops on background. No BGTask.

## Conflict resolution

**Last-write-wins by card-level timestamp.** Picked over field-level LWW because FenixKanban only tracks `Card.updatedAt`, not per-field timestamps. Picked over Fizzy-always-wins because FenixKanban edits while offline shouldn't get silently discarded. Picked over UI-surface-conflict because this is a personal integration and the surface isn't worth the design weight in MVP.

Cost: edits to different fields of the same card within a single sync interval lose one side. Mitigation: 5-min poll means the window is small, and the user can see the cloud badge on each card to know what was last synced.

## First-sync direction

When pairing is established (token present + both board IDs chosen), the user picks one of two modes in `FizzyAuthView` before tapping **Pair and sync**:

1. **Replace local with Fizzy** (default, recommended) — local cards on the paired board are deleted; full pull from Fizzy. Confirmation dialog warns this is destructive.
2. **Keep local, merge if no conflicts** — push local cards as new (each gets a `fizzyID`), pull remote cards, no merge if both sides have cards with the same title (skipped with a SyncResult.errors entry).

Defaulting to #1 avoids messy initial-merge edge cases; #2 is the escape hatch for the user who's set up locally first.

## UI

### `SyncSettingsView` (modified)

Always shows a single **Fizzy** row. Three visual states, all routing to `FizzyAuthView` on tap:

- **Not configured:** "Not connected" subtitle, gray cloud icon.
- **Token set, unpaired:** "Connected as @<user>", green checkmark, "No board paired" subtitle.
- **Paired:** "Connected as @<user>", "Board: <local-name> ↔ <fizzy-name>", "Last sync: 2 min ago" subtitle, inline **Sync now** button.

### `FizzyAuthView` (new)

Single sheet with three logical sections inside a `Form`:

- **Connection** — `Server URL` (TextField), `Access token` (SecureField with eye-toggle), `Account slug` (TextField), `Verify connection` button. On success: shows `✓ Signed in as <email>` from `GET /my/identity`.
- **Pair a board** — `Local board` (Picker of FenixKanban Boards), `Fizzy board` (Picker of remote boards from `GET /:account/boards`), `Pull options` (the two modes above), `Pair and sync` button.
- **Disconnect** — Destructive button that clears Keychain entries, the pairing, and nulls `fizzyID`/`fizzyEtag`/`fizzyUpdatedAt` on every Card in the paired board (so a future re-pair starts clean).

### `CardView` (modified)

Adds a small cloud badge next to existing `GoldZoneChip` / `DueDateBadge` when the card is part of a paired board:

| State | Symbol | Color |
|---|---|---|
| In sync | `cloud.fill` | secondary gray |
| Push pending (offline / queued) | `cloud.slash` | orange |
| Sync error on this card | `cloud.exclamationmark` | red |
| Not paired / `fizzyID == nil` | (none) | — |

Tapping a card with an error badge opens `CardDetailView`, which surfaces the error banner.

**Liquid Glass.** All new chrome uses stock `Form` / `Section` / `Picker` / `SecureField` / `Button`. No custom `.background(...)` on full-bleed views per `CLAUDE.md`'s Liquid Glass rule.

## Errors & offline behavior

| Condition | Behavior |
|---|---|
| Transient network failure (timeout, DNS, connection drop) | Retry 3× with exponential backoff (1s/2s/4s) inside the cycle; if still failing, return `SyncResult.errors: ["network: …"]`. No alert UI — surface via cloud badge + "Last sync failed (network)" caption. |
| 401 Unauthorized | Token revoked/expired. Provider clears in-memory token (NOT Keychain — avoids racing the user re-entering it), transitions to "Not configured", surfaces banner in `SyncSettingsView`. |
| 403 / 404 | Paired board unreachable. Stays paired, surfaces persistent banner. Suspends scheduled syncs until resolved. |
| 422 Unprocessable | API rejected one write. Per-card error in `SyncResult.errors`, sets red cloud badge. Other cards in cycle proceed. |
| 500 server error | Same path as transient network — retry then surface. |
| 429 rate limit | Honor `Retry-After`, back off, resume normal cadence after. |
| Offline (NWPathMonitor) | Skip scheduled sync entirely. Local edits still write to CoreData immediately. When network returns, the next scheduled sync picks up pending pushes. |

## Security

- **Token at rest:** Keychain via `KeychainHelper.save` (same protection class as the existing Apple ID token).
- **Token in transit:** TLS only via stock `URLSession`. No cert pinning — bluefenix.net's cert is publicly trusted, and pinning adds breakage risk without meaningful gain for a personal integration.
- **Token never in URL params.** Bearer header only.
- **Token redaction in logs:** helper `String.fizzyRedacted` truncates the middle 80% with `…` for any `print`/`os_log` calls that might capture a token. All logging in `FizzyClient` goes through this.
- **`signOut()` is destructive on purpose** — clears Keychain entries, the UserDefaults pairing, *and* nulls `fizzyID`/`fizzyEtag`/`fizzyUpdatedAt` on every Card in the paired board. No half-disconnected state.

## Testing

~30 new tests across five files. Full breakdown:

**`FizzyClientTests`** — mocked `URLProtocol`, no live network:
- Bearer header construction
- `:account_slug` path interpolation
- `If-None-Match` round-trip; 304 → `nil` body with ETag preserved
- 401/403/404/422 → specific `FizzyError` cases
- Transient retry (3× exponential, stops on 4xx)
- 429 Retry-After honored

**`FizzyDTOTests`** — golden-file decode against `FenixKanbanTests/Fixtures/fizzy/*.json`:
- `board.json` round-trip
- `cards.json` (mixed sample: golden=true, tagged, with description, with image_url, with assignees)
- Unsynced fields (`assignees`, `comments_count`) decode without crashing — confirms we don't break on payload growth

**`FizzyBoardMappingTests`**
- UserDefaults round-trip for all three keys
- `clear()` empties all three
- `isPaired` predicate reflects state correctly

**`FizzySyncEngineTests`** (the bulk — fully mocked client):
- Pull-only: 3 remote, 0 local → 3 local created with `fizzyID`
- Push-only: 1 local with `nil fizzyID`, 0 remote → 1 POST, returned ID stored
- Update from remote (LWW): remote newer → local updated
- Update from local (LWW): local newer → PATCH issued
- Conflict resolution: both differ; remote-wins case and local-wins case
- Tag auto-create on pull: remote `tags: ["new"]` not seen locally → local `Label` created with deterministic color
- Column name match (case-insensitive trimmed)
- Column auto-create on pull
- Column NOT auto-created on push; SyncResult.errors entry added
- Soft-delete on missing remote
- Crash-after-POST recovery: title+createdAt window matches orphan, no duplicate
- 401 path: provider transitions to "Not configured", banner surfaces
- Idempotence: re-running the same sync makes no changes the second time

**`FizzySyncProviderTests`**
- All 7 `BoardSyncProvider` methods route correctly
- `register()` only when token+slug present
- `signOut()` clears Keychain + mapping + per-Card sync columns

**No new UI tests** — same rationale as the appearance-mode picker. The bindings are conventional; the value is in the engine tests.

**Test fixtures.** Captured by running `bin/dev` against a local Fizzy instance (or against fizzy.bluefenix.net with the dev token) and saving verbatim. Documented in `FenixKanbanTests/Fixtures/fizzy/README.md`. Refresh process is part of the spec so future maintainers know how to regenerate.

**Target full-suite size after merge:** 161/161 (current 131 + ~30 new). Runs on every PR via existing `swift-pr-check.yml`.

## Build sequence

Six phases, each its own PR. Linear dependency chain; each ships verifiable behavior.

1. **`FizzyClient` + DTOs + `FizzyError`** — plumbing only. ~12 tests. Zero behavior change in the app.
2. **`FizzyAuthState` + `FizzyBoardMapping`** — Keychain + UserDefaults wrappers. ~6 tests. Still no UI.
3. **CoreData migration to `FenixKanban 3.xcdatamodel`** — three optional Card attributes. ~3 tests + CloudKit smoke.
4. **`FizzySyncEngine`** — diff + apply logic, fully mocked client. ~15 tests. Engine works in tests; not yet wired to app.
5. **UI: `SyncSettingsView` overhaul + `FizzyAuthView`** — token paste, verify, pair, manual "Sync now". First phase pointed at the real fizzy.bluefenix.net.
6. **Foreground poll timer + `CardView` cloud badges** — final polish.

**Total estimate:** ~30 tests, ~700 LOC, 1 lightweight CoreData migration. Comparable in scope to the golden-ticket feature (24 commits, 127→131 tests).

## Success criteria

- [ ] `swift build` succeeds for both iOS and macOS targets with no warnings.
- [ ] All ~30 new tests pass; full suite 161/161.
- [ ] Token paste flow stores credentials in Keychain; `Verify connection` confirms via `GET /my/identity`.
- [ ] Pairing UI shows live Fizzy boards from `GET /:account/boards`.
- [ ] **Replace local with Fizzy** mode wipes the paired board's local cards and pulls Fizzy state.
- [ ] Edit a card title in FenixKanban → next sync PATCHes Fizzy; refresh Fizzy in browser, title updated.
- [ ] Edit a card title in Fizzy → next sync (manual or after 5 min) pulls the change.
- [ ] Toggle `golden` in either side → next sync reflects on the other.
- [ ] Add a tag in Fizzy → label appears in FenixKanban with a deterministic auto-color.
- [ ] Move a card between columns on either side → next sync reflects on the other.
- [ ] `signOut()` clears Keychain + pairing + per-Card sync columns.
- [ ] CI passes on every phase's PR.

## Risks & open questions

- **Column matching by name is fragile.** If the user renames a column in Fizzy, the next sync sees an "unmatched" remote column and auto-creates a duplicate locally. Mitigation: phase-2 (post-MVP) could store `fizzyColumnID` on local Column; for now, document the limitation in the UI ("Don't rename columns while paired").
- **No optimistic UI.** A card edit waits until the next sync to round-trip to Fizzy. For one-off edits that's fine; for a flurry of edits the 5-minute poll might feel slow. Mitigation: phase-2 push-on-edit (debounced).
- **Activities feed is not wired in.** Could later detect remote changes faster (sub-minute). Recorded as future optimization.
- **Subtask / "steps" feature** is in Fizzy but not in FenixKanban. Out of scope; revisit when subtasks land locally.
- **`bluefenix.net` cert/IP changes** would manifest as 401-ish/network failures. The "Server URL" field is editable so the user can repoint without a rebuild.
