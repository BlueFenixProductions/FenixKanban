import Foundation

/// Persists the singleton pairing between one local `Board` and one Fizzy board.
///
/// Storage lives in the injected `UserDefaults` (default `.standard`). Tests
/// pass a private `UserDefaults(suiteName:)` so they never touch the user's
/// real defaults.
///
/// Phase 2 of the Fizzy integration; Phase 4's sync engine reads this to decide
/// what to sync, and Phase 5's `FizzyAuthView` writes it after the user picks
/// a pair.
final class FizzyBoardMapping {

    private static let localBoardKey = "fizzy.pairing.localBoardID"
    private static let fizzyBoardKey = "fizzy.pairing.fizzyBoardID"
    private static let lastSyncKey   = "fizzy.pairing.lastSyncAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// UUID of the paired local FenixKanban `Board`, or `nil` if unpaired.
    var localBoardID: UUID? {
        guard let string = defaults.string(forKey: Self.localBoardKey) else { return nil }
        return UUID(uuidString: string)
    }

    /// Opaque Fizzy board ID (e.g. `"03f5v9zkft4hj9qq0lsn9ohcm"`), or `nil`.
    var fizzyBoardID: String? {
        defaults.string(forKey: Self.fizzyBoardKey)
    }

    /// Timestamp of the most recent successful sync, or `nil` if never synced.
    var lastSyncAt: Date? {
        guard let string = defaults.string(forKey: Self.lastSyncKey) else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    /// `true` when both IDs are present — the predicate gating sync.
    var isPaired: Bool {
        localBoardID != nil && fizzyBoardID != nil
    }

    /// Sets both pairing IDs atomically.
    func setPairing(localBoardID: UUID, fizzyBoardID: String) {
        defaults.set(localBoardID.uuidString, forKey: Self.localBoardKey)
        defaults.set(fizzyBoardID, forKey: Self.fizzyBoardKey)
    }

    /// Records a successful sync.
    func setLastSync(_ date: Date) {
        defaults.set(ISO8601DateFormatter().string(from: date), forKey: Self.lastSyncKey)
    }

    /// Removes all three keys.
    func clear() {
        defaults.removeObject(forKey: Self.localBoardKey)
        defaults.removeObject(forKey: Self.fizzyBoardKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
    }
}
