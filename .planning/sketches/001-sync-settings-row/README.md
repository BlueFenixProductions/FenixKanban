---
sketch: 001
name: sync-settings-row
question: "How should the SyncSettingsView row express provider state at a glance?"
winner: "C"
tags: [list-row, status, sync-settings]
---

# Sketch 001: SyncSettingsView row

## Design Question
With Fizzy as the first real `BoardSyncProvider`, the row needs to communicate
three primary states without making the user tap in: *not set up*, *connected
& healthy*, *connected but action needed* (e.g. 401 mid-session).

## How to View
open .planning/sketches/001-sync-settings-row/index.html

## Variants
- **A: icon + checkmark only** — minimal, but badge meaning is ambiguous.
- **B: icon + subtitle + status text + chevron** — fully self-explanatory; rows are tall.
- **C: icon + subtitle + trailing badge + chevron** — hybrid; mid-density.

## What to Look For
- Can you tell at a glance which provider needs attention?
- Does the row height feel native to iOS (44pt minimum, comfortable touch target)?
- Does the badge meaning resolve without reading the subtitle?
- How does the row scale if a second Fizzy account is added later?
