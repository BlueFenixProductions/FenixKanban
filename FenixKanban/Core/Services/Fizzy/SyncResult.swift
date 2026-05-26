import Foundation

/// Outcome of a Fizzy sync operation. Counters track per-card transitions;
/// `errors` carries human-readable warnings (e.g. "Local column 'Foo' has no
/// Fizzy match" or "Same-title collision: 'Buy milk'").
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

    /// Merges another result into a copy of this one. Used to combine the
    /// outcomes of multiple per-card or per-column passes within a single
    /// sync cycle.
    func combined(with other: FizzySyncResult) -> FizzySyncResult {
        FizzySyncResult(
            itemsCreated: itemsCreated + other.itemsCreated,
            itemsUpdated: itemsUpdated + other.itemsUpdated,
            itemsDeleted: itemsDeleted + other.itemsDeleted,
            errors: errors + other.errors
        )
    }
}
