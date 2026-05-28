---
sketch: 004
name: fizzy-auth-status
question: "How should the paired status + 401 banner read in normal vs error states?"
winner: "A"
tags: [auth, status, 401, fizzy]
---

# Sketch 004: FizzyAuthStatusView

## Design Question
After pairing, this is the screen the user returns to: status (board name, last
sync), "Sync now", "Sign out". The screen also has to handle the 401 case —
when the engine has cleared `authState`, the user needs an obvious recovery path.
Three placements for the recovery message:

## How to View
open .planning/sketches/004-fizzy-auth-status/index.html

## Variants
- **A: banner ABOVE status** — yellow banner appears at top; status stays
  visible underneath. Sync Now button reads "Sync Paused" (disabled). User
  sees current state AND the recovery prompt simultaneously.
- **B: banner REPLACES status** — status hero hides; full-bleed warning
  replaces it. The screen has one thing to do: re-enter the token. Cleanest
  but loses the "what was the last good state" context.
- **C: status block TRANSFORMS** — same hero card morphs in-place: icon turns
  warning-yellow, title becomes "Sync paused", subtitle becomes the recovery
  message, metrics replaced by the CTA. No layout shift; familiar surface,
  new content.

## What to Look For
- Cycle Healthy → Syncing → 401 on each variant. Which transition feels least
  jarring?
- When 401 is active, can you immediately tell what to do next?
- In Variant A, does the duplicate "Sync Paused" + the banner feel redundant
  or reinforcing?
- In Variant B, do you miss the context of "last successful sync was 2 hours ago"?
  (It's in the banner copy — does that scan?)
- In Variant C, does the in-place transformation feel too clever, or does the
  reduced layout movement help?
