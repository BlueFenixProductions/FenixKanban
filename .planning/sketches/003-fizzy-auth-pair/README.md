---
sketch: 003
name: fizzy-auth-pair
question: "How should 3 pickers + a destructive-mode warning + a backup banner coexist without overwhelming?"
winner: "D-synth"
tags: [auth, pair, destructive, backup, fizzy]
---

# Sketch 003: FizzyAuthPairView

## Design Question
After token verification, the user picks: which local board, which Fizzy board,
which first-sync mode. The picker for *first-sync mode* can be destructive
(`replaceLocalWithFizzy` wipes the local board) — the screen must surface that
risk loudly without nagging during the common non-destructive path. A backup
recommendation banner is also present at the top until dismissed.

## How to View
open .planning/sketches/003-fizzy-auth-pair/index.html

## Variants
- **A: Stacked sections, disclosure-on-destructive** — every concern gets its
  own grouped section; warning materializes only under the mode picker when
  destructive is selected. Most "standard iOS Settings".
- **B: Always-visible status banner under mode picker** — a status banner under
  the segmented control color-shifts (info/danger) based on mode. Less spatial
  movement; warning is always proportional to mode choice.
- **C: Dynamic warning + adaptive primary** — single consolidated picker card;
  warning materializes only on destructive pick AND the primary "Pair & Sync"
  button transforms into a red "Delete & Replace" button. Maximum signal that
  the upcoming action is destructive; minimum content otherwise.
- **D ★ SYNTHESIS** — A's stacked grouped sections (best iOS-Settings feel) + C's
  three signals when destructive is picked: red-tinted segment, inline warning
  row, adaptive primary button (`Pair & Sync` → `Delete & Replace`). Plus the
  confirmation alert. **Selected.**

## What to Look For
- Tap through the mode cycler (Push → Replace → Merge) on each variant. Which
  variant makes the destructive risk most obvious without being noisy in normal use?
- Where does the backup banner sit best? Top-of-page nag, or could it live
  elsewhere?
- The local-board picker shows "Roadmap" — assume the user has 3 local boards
  in real life. Does the picker placement feel right when it's a navigation
  push (vs inline)?
- Tap Pair & Sync with Replace selected on each — does the confirmation alert
  feel like enough friction, or does Variant C's adaptive button make the alert
  feel redundant?
