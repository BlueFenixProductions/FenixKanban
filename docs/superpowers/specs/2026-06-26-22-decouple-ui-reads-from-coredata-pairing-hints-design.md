# Decouple UI/runtime reads from CoreData pairing hints (#22, safe subset)

**Date:** 2026-06-26
**Issue:** #22 (CoreData pairing-attribute cleanup) — *safe-decoupling subset only*
**Status:** Design approved; ready for implementation plan.

## Goal

Flip every runtime/UI reader of the CoreData pairing-hint attributes
(`card.fizzyNumber`, `card.fizzyID`) so it asks the device-local
`FizzyCardPairingStore` **first**, falling back to the CoreData attribute only
when the store has no entry for that card yet. This makes the store the
published source of truth for "is this card paired, and what is its Fizzy
number/id" without touching the migration, the hint-write machinery, or the
attributes themselves.

This is the **safe, ungated subset** of #22. The actual CoreData attribute
removal (a future **v10** model version) and deletion of the hint
write/seed/heal channel remain **deferred and gated** (one full release cycle
with zero hint-seed events) and are explicitly out of scope here.

## Boundary: what changes, what stays

**Changes (readers only):**

- New `Card+Pairing.swift` helper that centralizes the store-first-with-fallback
  resolution.
- View-models / views that currently branch or compute on `card.fizzyNumber` /
  `card.fizzyID` switch to the helper.

**Stays exactly as-is (the hint channel — gated to v10):**

- `FizzySyncEngine.seedPairingStoreFromHints` + `healHints` (cold-store seeding
  and orphan-claim healing).
- Hint *writes* and tombstone fallbacks: `CardRepository:111` /
  `BoardRepository` (`… ?? card.fizzyNumber` write-side reads stay — they are
  the seam that keeps the hint channel coherent until v10).
- All CoreData attributes: `fizzyID`, `fizzyNumber`, `fizzyUpdatedAt`,
  `fizzyEtag`. No model version bump. No renames (forbidden per the v5→v6
  CloudKit ruling; v10 will be remove-only).
- `CardView:43` already reads the store directly (`FizzyCardPairingStore.shared
  .pairing(for: cardID) != nil`) — no change.

## Read strategy decision: store-first with attribute fallback

**Chosen** (Captain's call, 2026-06-26): store-first, attribute fallback —
matching the existing `CardRepository:111` precedent verbatim:

```swift
let number = card.id.flatMap { pairingStore.pairing(for: $0)?.fizzyNumber } ?? card.fizzyNumber
```

**Why, not pure store-only:** on a cold device, a card can carry a CloudKit
hint attribute *before* `seedPairingStoreFromHints` has populated the store for
this launch. A pure store-only read would render that card **unpaired** during
that transient window — a regression. The fallback closes that window at zero
cost: store value wins when present, attribute answers otherwise.

**Forward path to v10:** because the fallback is isolated in one helper, the
v10 cleanup collapses to deleting the `?? card.fizzyNumber` / `?? fizzyID`
tail inside `Card+Pairing.swift` (and the now-dead attributes), instead of a
9-file sweep.

## The shared helper (`FenixKanban/Core/Persistence/Card+Pairing.swift`)

A focused `Card` extension, sibling to `Card+Lifecycle.swift`. The store is
passed in (never defaulted) so callers keep using their injected store for
testability — consistent with the `init(context:, pairingStore:)` convention.

```swift
import CoreData

extension Card {
    /// Fizzy card number, store-first with CoreData-hint fallback (#22).
    /// Store wins when a pairing exists; the `fizzyNumber` attribute answers
    /// only during the pre-seed window on a cold device. Returns 0 when the
    /// card is unpaired in both — preserving the `> 0` paired gate.
    func resolvedFizzyNumber(_ store: FizzyCardPairingStore) -> Int64 {
        id.flatMap { store.pairing(for: $0)?.fizzyNumber } ?? fizzyNumber
    }

    /// Fizzy card id, store-first with CoreData-hint fallback (#22).
    func resolvedFizzyID(_ store: FizzyCardPairingStore) -> String? {
        id.flatMap { store.pairing(for: $0)?.fizzyID } ?? fizzyID
    }
}
```

The `> 0` paired gate and `Int(...)` client-call conversions are preserved at
each call site — only the *value source* changes.

## Per-site reader changes

Each converted view-model that does not already hold a pairing store gains a
`pairingStore: FizzyCardPairingStore = .shared` init parameter (matching the
repository convention), stored privately, and passed into the helper.

- **CardDetailViewModel** (`Features/Card/CardDetailViewModel.swift`)
  — the densest site. Add `pairingStore` to `init`. A private computed
  `resolvedFizzyNumber` (`card.resolvedFizzyNumber(pairingStore)`) replaces
  every `card.fizzyNumber` read: the construction guard (line 59), the
  `cardFizzyNumber:` argument to `CardCommentsViewModel` (line 63), the
  `isFizzyPaired` gate (line 171), and the `> 0` guard + `Int(card.fizzyNumber)`
  client-call argument in each of `toggleLabel`, `toggleAssignment`,
  `toggleWatched`, `togglePinned`, `toggleGolden`, `closeCard`, `reopenCard`,
  `postponeCard`.
- **BoardViewModel** (`Features/Board/BoardViewModel.swift`) — `pushGolden`
  and `performLifecycleAction` paired guards + number reads.
- **CardStepsViewModel** / **CardCommentsViewModel** — receive an
  already-resolved `cardFizzyNumber` from `CardDetailViewModel`'s construction
  site, so the resolution happens once at construction. Verify neither re-reads
  `card.fizzyNumber` directly; if one does, convert that read too.
- **FizzySyncProvider** (`Features/Sync/Fizzy/FizzySyncProvider.swift`) —
  retry-pending-steps read.
- **FizzyAuthStatusView** — the `fizzyID != nil` predicate / count that drives
  the paired-cards status display → store-backed (`allPairings()` count or
  per-card `pairing(for:)`).

The exact lines for the non-CardDetailViewModel sites are enumerated by the
implementation plan; this spec fixes the *pattern* and the *file set*.

## Testing

- **Helper unit test** (`Card+Pairing`): both branches — (a) store empty,
  attribute set → returns the attribute value (fallback); (b) store entry
  present and *differing* from the attribute → returns the store value
  (store wins). Same two cases for `resolvedFizzyID`.
- **Per-converted-view-model test:** prove the converted reader honors the
  store. At minimum, inject a store with a pairing whose `fizzyNumber` differs
  from the card's attribute and assert the paired-path behavior follows the
  store; and a store-empty + attribute-set case asserting no paired-state
  regression (the cold-device window).
- **Gate before push:** `make symbols` (phantom-symbol sweep), the full
  affected test suites, and `xcodebuild build -destination generic/platform=macOS`.

## Out of scope (recorded for v10)

- Removing `fizzyID` / `fizzyNumber` / `fizzyUpdatedAt` / `fizzyEtag` from the
  CoreData model (new `FenixKanban 10.xcdatamodel`, remove-only).
- Deleting `seedPairingStoreFromHints` / `healHints` and the hint *writes*.
- Deleting the `?? card.fizzyNumber` / `?? fizzyID` fallback tails in
  `Card+Pairing.swift`.

These stay gated on one full release cycle with zero hint-seed telemetry, per
the #22 decision thread.
