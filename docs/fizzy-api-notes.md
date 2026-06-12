# Fizzy API — live-probed answers (2026-06-12, fizzy.bluefenix.net, account `1`)

Empirical answers from the mission #28 probe session (sacrificial `[itest]`
cards on the Sandbox board; Playground untouched). These supersede guesses in
older specs.

## Card listing & lifecycle

- `GET /boards/:id/columns/:col/cards` lists **only cards triaged into that
  column**. Untriaged (triage-inbox) cards appear in NO column list — they are
  only visible via the board-wide `GET /cards?board_ids[]=`. Closed/not-now
  cards are also excluded from column lists. ⇒ absence from column lists never
  proves deletion (engine confirms via `GET /cards/:n`; 404 = gone).
- The board-wide list shape carries `status` (publish state) + `closed` +
  `postponed` but **no `column`** — per-column endpoints are the only list
  source of column placement.
- New cards born via `POST /boards/:id/cards` start **untriaged**; triage with
  `POST /cards/:n/triage` `{"column_id": …}`.

## Tags

- `POST /cards/:n/taggings` body `{"tag_title": "…"}` → **204; toggles** the
  tag on/off. Unknown tags are auto-created account-wide; leading `#` stripped.
- `PUT /cards/:n` with `card.tag_ids` → **400** on this server build. ⇒ tag
  push must be implemented as **exact toggle diffing** (local minus remote →
  toggle on; remote minus local → toggle off). Toggles are not idempotent —
  diff must be computed against fresh remote state.

## Assignments

- `POST /cards/:n/assignments` body `{"assignee_id": "<user id>"}` → 204;
  **toggles** assignment, symmetric with taggings.
- `GET /:account/users` is the directory (sole user on this instance:
  Chris Pelatari).

## HTTP details

- `Location` headers on 201 come **relative with a `.json` suffix**
  (`/1/cards/262.json`); the client's `URL(string:relativeTo:)` handling
  covers it.
- Per-column card lists carry **per-column ETags** (observed on every column;
  single-page lists on this board). Multi-page ETag grain remains unverified —
  the engine's single-page-only conditional rule stays.
- `Retry-After` format unprobed (no polite way to force a 429 on a live
  instance); the client accepts numeric seconds and caps at 30.

## Account/identity quirks

- `/my/identity` slugs carry a leading `/` (`"/1"`); normalize before
  interpolating into paths (client already does).
- This is a self-hosted single-account instance: slug `1`, boards
  Playground / Sandbox ×2.
