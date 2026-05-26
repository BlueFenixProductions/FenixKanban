import Foundation

// MARK: - Fizzy Sync Results

/// Outcome of a Fizzy sync operation. Counters track per-card transitions; `errors`
/// carries human-readable warnings (e.g. "Local column 'Foo' has no Fizzy
/// match" or "Same-title collision: 'Buy milk'").
///
/// Internal type used by `FizzySyncEngine`. Distinct from the public
/// `BoardSyncProvider.SyncResult` protocol return type — this one has mutable
/// fields, defaults, and a `combined(with:)` method; the protocol's version
/// is immutable with a `syncDate` field.
///
/// Note: Module-scope naming conflict workaround — this type is suffixed with
/// `Fizzy` internally but accessible as `Fizzy.SyncResult` via the namespace
/// export below.
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

// MARK: - Namespace convenience

/// Fizzy sync types namespace. Use `Fizzy.SyncResult` to access the sync result type.
enum Fizzy {
    typealias SyncResult = FizzySyncResult
}
