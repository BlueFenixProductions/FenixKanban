import Testing
import Foundation
@testable import FenixKanban

/// Pure-function tests for the state derivation. No provider, no I/O —
/// covers the three states (`notConfigured`, `unpaired`, `paired`) plus the
/// "token gate wins" guard.
@Suite("BoardFizzySyncModel.derive")
@MainActor
struct BoardFizzySyncModelDeriveTests {

    @Test("notConfigured when no token and no pairing")
    func notConfiguredNoTokenNoPairing() {
        #expect(BoardFizzySyncModel.derive(isConfigured: false, pairing: nil) == .notConfigured)
    }

    @Test("notConfigured when no token even if a pairing exists (token gate wins)")
    func notConfiguredTokenGateWins() {
        let p = FizzyBoardPairing(localBoardID: UUID(), fizzyBoardID: "fz", syncEnabled: true)
        #expect(BoardFizzySyncModel.derive(isConfigured: false, pairing: p) == .notConfigured)
    }

    @Test("unpaired when token present and no pairing")
    func unpairedWhenTokenPresent() {
        #expect(BoardFizzySyncModel.derive(isConfigured: true, pairing: nil) == .unpaired)
    }

    @Test("paired(enabled: true) reflects syncEnabled flag with nil lastSyncAt")
    func pairedEnabledNilLastSync() {
        let p = FizzyBoardPairing(localBoardID: UUID(), fizzyBoardID: "fz", syncEnabled: true)
        #expect(
            BoardFizzySyncModel.derive(isConfigured: true, pairing: p)
                == .paired(enabled: true, lastSyncAt: nil)
        )
    }

    @Test("paired(enabled: false) reflects syncEnabled=false and carries lastSyncAt")
    func pairedPausedCarriesLastSync() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let p = FizzyBoardPairing(
            localBoardID: UUID(),
            fizzyBoardID: "fz",
            lastSyncAt: when,
            syncEnabled: false
        )
        #expect(
            BoardFizzySyncModel.derive(isConfigured: true, pairing: p)
                == .paired(enabled: false, lastSyncAt: when)
        )
    }
}
