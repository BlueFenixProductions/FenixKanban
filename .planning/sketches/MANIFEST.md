# Sketch Manifest

## Design Direction
iOS 26 / Liquid Glass — translucent surfaces over a soft gradient, SF-stack
typography, standard List/Form grouping. Mockups intentionally evoke the
visual idiom of Apple's own Settings app rather than inventing custom chrome.
Fizzy is the load-bearing first `BoardSyncProvider`; sketches focus on the
auth and pairing surfaces (Phase 5) plus the destructive-mode safety
treatments that ride on Phase 4c's backup feature.

## Reference Points
Native iOS Settings (token paste, picker rows, segmented controls),
Tailscale's auth screens (token + verify pattern), Working Copy's repo
pairing UI (multi-picker setup), iOS 17 Apple ID warning state (banner +
in-place transformation idioms).

## Sketches

| # | Name | Design Question | Winner | Tags |
|---|------|----------------|--------|------|
| 001 | sync-settings-row | How should the SyncSettingsView row express provider state at a glance? | **C** — hybrid: icon + subtitle + trailing badge + chevron | list-row, status, sync-settings |
| 002 | fizzy-auth-verify | What's the right density for the token-paste verify form? | **A** — form-style, full-bleed grouped section + footer button | auth, form, fizzy, verify |
| 003 | fizzy-auth-pair | How should 3 pickers + destructive warning + backup banner coexist? | **D (synth)** — A's stacked sections + C's destructive-segment color + adaptive primary button | auth, pair, destructive, backup, fizzy |
| 004 | fizzy-auth-status | How should paired status + 401 banner read in normal vs error states? | **A** — banner above status (preserves context, two simultaneous signals) | auth, status, 401, fizzy |

## Key Decisions Locked

- **Status visualization** — badge color + glyph carry the meaning (✓/⚠), with subtitle for action verbs.
- **Auth verify** — standard iOS Settings form with footer-area primary; no hero treatment.
- **Pairing** — stacked grouped sections, destructive mode is color-coded in the segmented control AND triggers an inline warning AND adapts the primary button text + color.
- **Status + 401** — yellow banner appears above the status hero; "Sync Now" disables to "Sync Paused"; status hero stays visible for context.
- **Backup banner** — dismissable (per-`UserDefaults`), info-styled, sits at the top of `FizzyAuthPairView` only.
- **Confirmation alerts** — destructive mode always requires a second confirmation alert with the card count visible.
