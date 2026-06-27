import Foundation
import Observation

/// Board-scoped view model for the per-board Fizzy Sync menu (issue #18
/// follow-on). Derives state synchronously from local stores and delegates
/// every action to `FizzySyncProvider` — no sync logic is duplicated here.
@MainActor
@Observable
final class BoardFizzySyncModel {

    enum State: Equatable {
        case notConfigured                              // no token
        case unpaired                                   // token present, no pairing for this board
        case paired(enabled: Bool, lastSyncAt: Date?)   // pairing exists
    }

    /// Pure projection — three inputs, one state. Token gate wins: no token
    /// means `.notConfigured` no matter what the pairing store says.
    static func derive(isConfigured: Bool, pairing: FizzyBoardPairing?) -> State {
        guard isConfigured else { return .notConfigured }
        guard let pairing else { return .unpaired }
        return .paired(enabled: pairing.syncEnabled, lastSyncAt: pairing.lastSyncAt)
    }
}
