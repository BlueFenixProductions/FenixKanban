import Foundation

// MARK: - ConflictRecord

/// A detected LWW conflict for a single card: both local and remote sides
/// moved title or description since the last sync watermark.
///
/// Transient in `FizzySyncResult.conflicts`; durably stored per-card in
/// `FizzyConflictStore` until the user resolves it. Keyed by local card UUID —
/// the `id` field is the UUID of the local `Card` entity, not the Fizzy card id.
struct ConflictRecord: Equatable, Codable, Identifiable {
    /// Local card UUID (CoreData entity id).
    var id: UUID
    /// Fizzy card number (for re-fetch and PUT routes).
    var fizzyNumber: Int64
    var localTitle: String
    var localDescription: String?
    var remoteTitle: String
    var remoteDescription: String?
    var detectedAt: Date
}

// MARK: - FizzySyncResult

/// Outcome of a Fizzy sync operation. Counters track per-card transitions;
/// `errors` carries human-readable warnings (e.g. "Local column 'Foo' has no
/// Fizzy match" or "Same-title collision: 'Buy milk'").
///
/// `conflicts` carries detected LWW title/description conflicts for the cycle;
/// each entry is also persisted to `FizzyConflictStore` by the engine.
///
/// Distinct from the public `BoardSyncProvider.SyncResult` returned by the
/// protocol method `sync(boardId:remoteProjectId:)` — that one is immutable
/// with a `syncDate` field. `FizzySyncEngine` builds this incrementally and
/// Phase 5's `FizzySyncProvider` translates it to the protocol shape at
/// the boundary.
struct FizzySyncResult: Equatable {
    var itemsCreated: Int = 0
    var itemsUpdated: Int = 0
    var itemsDeleted: Int = 0
    var errors: [String] = []
    /// Conflicts detected during this cycle (title or description diverged on
    /// both sides since the last watermark). Durably stored in
    /// `FizzyConflictStore`; this array is the transient per-cycle view.
    var conflicts: [ConflictRecord] = []

    /// Merges another result into a copy of this one. Used to combine the
    /// outcomes of multiple per-card or per-column passes within a single
    /// sync cycle.
    func combined(with other: FizzySyncResult) -> FizzySyncResult {
        FizzySyncResult(
            itemsCreated: itemsCreated + other.itemsCreated,
            itemsUpdated: itemsUpdated + other.itemsUpdated,
            itemsDeleted: itemsDeleted + other.itemsDeleted,
            errors: errors + other.errors,
            conflicts: conflicts + other.conflicts
        )
    }

    /// Folds `other` into this result in-place. Used by the multi-board
    /// scheduler (Task 5) to accumulate per-board results into a single
    /// aggregate before updating `SyncActivityState`.
    mutating func merge(_ other: FizzySyncResult) {
        itemsCreated += other.itemsCreated
        itemsUpdated += other.itemsUpdated
        itemsDeleted += other.itemsDeleted
        errors += other.errors
        conflicts += other.conflicts
    }
}
