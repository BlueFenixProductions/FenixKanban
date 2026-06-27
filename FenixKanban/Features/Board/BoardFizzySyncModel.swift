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

    private let provider: FizzySyncProvider
    private let boardID: UUID
    private let boardName: String

    var actionError: String?
    var lastLinkCollisions: [String]?

    init(provider: FizzySyncProvider, boardID: UUID, boardName: String) {
        self.provider = provider
        self.boardID = boardID
        self.boardName = boardName
    }

    /// Synchronous projection from the auth state + this board's pairing.
    var state: State {
        Self.derive(
            isConfigured: provider.authStateRef.isConfigured,
            pairing: provider.boardPairingStoreRef.pairing(forLocal: boardID)
        )
    }

    // MARK: - Actions (RED 2: stubbed; GREEN 2 wires each to the provider)

    func toggleSync() {
        if let pairing = provider.boardPairingStoreRef.pairing(forLocal: boardID) {
            provider.setSyncEnabled(localBoardID: boardID, !pairing.syncEnabled)
        }
    }

    func syncNow() async {
        if let pairing = provider.boardPairingStoreRef.pairing(forLocal: boardID) {
            actionError = nil
            do {
                try await provider.sync(boardId: boardID, remoteProjectId: pairing.fizzyBoardID)
            } catch {
                actionError = "Couldn't sync the board: \(error)"
            }
        }
    }

    func unpair() {
        provider.unpair(localBoardID: boardID)
    }

    func createOnFizzy() async {
        actionError = nil
        lastLinkCollisions = nil
        do {
            _ = try await provider.createRemoteTwin(localBoardID: boardID, name: boardName)
        } catch {
            actionError = "Couldn't create the board on Fizzy: \(error)"
        }
    }

    func linkExisting(toFizzyBoardID fizzyBoardID: String, fizzyBoardName: String?) async {
        actionError = nil
        lastLinkCollisions = nil
        do {
            let result = try await provider.linkExisting(
                localBoardID: boardID, fizzyBoardID: fizzyBoardID, fizzyBoardName: fizzyBoardName)
            if !result.errors.isEmpty { lastLinkCollisions = result.errors }
        } catch {
            actionError = "Couldn't link the boards: \(error)"
        }
    }

    func loadUnpairedRemoteBoards() async throws -> [RemoteBoard] {
        let remoteBoards = try await provider.fetchRemoteBoards()
        return remoteBoards.filter { provider.boardPairingStoreRef.pairing(forFizzy: $0.id) == nil }
    }
}
