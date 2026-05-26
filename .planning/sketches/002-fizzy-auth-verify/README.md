---
sketch: 002
name: fizzy-auth-verify
question: "What's the right density for the token-paste verify form?"
winner: "A"
tags: [auth, form, fizzy, verify]
---

# Sketch 002: FizzyAuthVerifyView

## Design Question
The first thing the user sees when wiring up Fizzy is the token-paste form.
It's a one-input one-button screen, but the visual treatment sets the tone for
the rest of the Fizzy auth flow. Each variant cycles through Idle / Verifying /
Error / Success states via the state-cycler buttons.

## How to View
open .planning/sketches/002-fizzy-auth-verify/index.html

## Variants
- **A: Form-style, full-bleed** — standard iOS grouped Form, "Verify" lives in a
  separate footer-area button. Familiar; most iOS Settings-like.
- **B: Card-on-form, inline button** — input + Verify share one rounded card,
  Verify glued to the bottom. Compact; reduces target distance from paste to confirm.
- **C: Centered hero** — large app-icon, centered title, floating input. Friendlier
  first-time impression; less compatible with Liquid Glass's preference for letting
  the system chrome breathe.

## What to Look For
- Does the input field stand out enough as the primary affordance?
- Where does your eye go after you've pasted: down to a button, or to a "next" CTA?
- Do all four states (idle/verifying/error/success) read clearly in the same layout?
- Which variant best previews how `FizzyAuthPairView` will look on the next screen?
