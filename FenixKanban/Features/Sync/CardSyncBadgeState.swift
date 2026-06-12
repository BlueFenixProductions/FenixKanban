import Foundation

/// Resolved sync-badge state for a single card.
///
/// Computed from device-local pairing facts — no network call needed.
/// Keeping the logic here (not inside `CardView`) means it can be
/// unit-tested without a live SwiftUI render pass.
enum CardSyncBadgeState: Equatable {
    /// The card has a Fizzy pairing entry — it has been synced at least once.
    case synced
    /// The board is paired but this specific card hasn't been synced yet.
    case pending
    /// Board is not paired; no badge should be shown.
    case none

    /// Pure-function resolution used by views and tests.
    ///
    /// - Parameters:
    ///   - hasPairing: `true` when `FizzyCardPairingStore` has an entry for this card's UUID.
    ///   - boardIsPaired: `true` when `FizzyBoardMapping.isPaired`.
    static func resolve(hasPairing: Bool, boardIsPaired: Bool) -> CardSyncBadgeState {
        guard boardIsPaired else { return .none }
        return hasPairing ? .synced : .pending
    }
}
