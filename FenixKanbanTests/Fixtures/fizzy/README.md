# Fizzy API Test Fixtures

Transcribed verbatim from `~/Documents/GitHub/fizzy/docs/api/sections/*.md` (the
37signals Fizzy OSS repo on this machine). These are hand-written, not captured
from a live API — Phase 1 ships before any live token wiring (that comes in
Phase 5).

## When to refresh

Refresh these whenever Fizzy upstream changes a wire format. The trigger is a
test failure on a DTO field name or type mismatch after pulling a newer Fizzy.

### Refresh procedure (post-Phase 5)

Once `FizzyClient` is wired to a real token, capture from the live instance:

```bash
TOKEN=$(security find-generic-password -a chris -s fizzy.accessToken -w)
SLUG=897362094  # your fizzy.bluefenix.net account slug
BASE=https://fizzy.bluefenix.net

curl -sH "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  "$BASE/my/identity" | jq . > identity.json
curl -sH "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  "$BASE/$SLUG/boards" | jq . > boards.json
```

For now (Phase 1), the hand-transcribed fixtures suffice.

## Files

- `identity.json` — `GET /my/identity`
- `boards.json` — `GET /:account/boards`
- `columns.json` — `GET /:account/boards/:board_id/columns`
- `cards.json` — `GET /:account/cards` (list endpoint; no `column` field per Fizzy docs)
- `card_single.json` — `GET /:account/cards/:number` (single-card endpoint; includes `column`, `steps`)

## Live captures (2026-06-12)

Captured verbatim from `fizzy.bluefenix.net` against the Playground board
(`03g6wodfwdenxzhzmcxxpl84t`) using the `claude/55-live-uat` branch wire. No
scrubbing — no tokens appear in payloads.

- `playground_columns.json` — `GET /1/boards/03g6wodfwdenxzhzmcxxpl84t/columns`
  (3 columns: Ready, Done, In Progress)
- `playground_column_cards.json` — `GET .../columns/03gaikln6car6gsnm1mln6pag/cards`
  both pages merged into a single array (32 FizzyCard objects from the Ready column).
  Each card carries the `column` field because it comes from the per-column endpoint.
- `playground_card_detail.json` — `GET /1/cards/100` (single-card detail;
  includes `column`, `steps`, `closed`, `assignees`)
