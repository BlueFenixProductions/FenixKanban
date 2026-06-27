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

/// Action-wiring tests. The model owns no sync logic — every action delegates
/// to `FizzySyncProvider`. These tests reuse the browser VM's harness
/// (`Harness` is `internal` for cross-suite use) so the provider is real,
/// HTTP is stubbed, and the pairing store is a temp sidecar.
@Suite("BoardFizzySyncModel actions", .serialized)
@MainActor
struct BoardFizzySyncModelActionTests {

    typealias Harness = FizzyBoardBrowserViewModelTests.Harness

    @Test("state reads through the provider: unpaired when token present + no pairing")
    func stateReadsThroughProvider() throws {
        let h = Harness(); defer { h.tearDown() }
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: UUID(), boardName: "Anything")
        #expect(model.state == .unpaired)
    }

    @Test("state becomes notConfigured when auth is cleared")
    func stateNotConfiguredWhenAuthCleared() throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.clear()
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: UUID(), boardName: "Anything")
        #expect(model.state == .notConfigured)
    }

    @Test("state becomes paired(enabled: true) when a pairing is upserted for the board")
    func statePairedReflectsPairing() throws {
        let h = Harness(); defer { h.tearDown() }
        let boardID = UUID()
        h.boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: boardID, fizzyBoardID: "fz-X", syncEnabled: true))
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: boardID, boardName: "X")
        #expect(model.state == .paired(enabled: true, lastSyncAt: nil))
    }

    @Test("toggleSync flips syncEnabled in the pairing store")
    func toggleSyncFlipsStore() throws {
        let h = Harness(); defer { h.tearDown() }
        let boardID = UUID()
        h.boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: boardID, fizzyBoardID: "fz-X", syncEnabled: true))
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: boardID, boardName: "X")

        model.toggleSync()
        #expect(h.boardPairingStore.pairing(forLocal: boardID)?.syncEnabled == false)

        model.toggleSync()
        #expect(h.boardPairingStore.pairing(forLocal: boardID)?.syncEnabled == true)
    }

    @Test("toggleSync is a no-op when the board is unpaired")
    func toggleSyncNoOpWhenUnpaired() throws {
        let h = Harness(); defer { h.tearDown() }
        let boardID = UUID()
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: boardID, boardName: "X")

        model.toggleSync()
        #expect(h.boardPairingStore.pairing(forLocal: boardID) == nil)
    }

    @Test("syncNow issues a network sync for the paired board")
    func syncNowIssuesNetwork() async throws {
        let h = Harness(); defer { h.tearDown() }
        FizzyBoardBrowserOrchestrationTests.stubCreateAndEmptySync(
            h.mock, newID: "unused", name: "n/a")
        let repo = BoardRepository(context: h.persistence.viewContext)
        let board = repo.createBoard(name: "X")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: board.id!, fizzyBoardID: "fz-X"))
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: board.id!, boardName: "X")
        h.mock.resetRequests()

        await model.syncNow()

        #expect(!h.mock.requests.isEmpty)
        #expect(model.actionError == nil)
    }

    @Test("syncNow is a no-op when the board is unpaired")
    func syncNowNoOpWhenUnpaired() async throws {
        let h = Harness(); defer { h.tearDown() }
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: UUID(), boardName: "X")
        h.mock.resetRequests()

        await model.syncNow()

        #expect(h.mock.requests.isEmpty)
    }

    @Test("unpair removes the pairing without deleting local data")
    func unpairRemovesPairingKeepsBoard() throws {
        let h = Harness(); defer { h.tearDown() }
        let repo = BoardRepository(context: h.persistence.viewContext)
        let board = repo.createBoard(name: "Solo")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: board.id!, fizzyBoardID: "fz-S"))
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: board.id!, boardName: "Solo")

        model.unpair()

        #expect(h.boardPairingStore.pairing(forLocal: board.id!) == nil)
        let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
        #expect(boards.contains { $0.id == board.id! })
    }

    @Test("createOnFizzy creates the twin and upserts the pairing on success")
    func createOnFizzySuccess() async throws {
        let h = Harness(); defer { h.tearDown() }
        FizzyBoardBrowserOrchestrationTests.stubCreateAndEmptySync(
            h.mock, newID: "fz-NEW", name: "Personal")
        let repo = BoardRepository(context: h.persistence.viewContext)
        let board = repo.createBoard(name: "Personal")
        try h.persistence.viewContext.save()
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: board.id!, boardName: "Personal")

        await model.createOnFizzy()

        #expect(h.boardPairingStore.pairing(forLocal: board.id!)?.fizzyBoardID == "fz-NEW")
        #expect(model.actionError == nil)
    }

    @Test("createOnFizzy populates actionError when the provider throws")
    func createOnFizzyErrorSetsActionError() async throws {
        let h = Harness(); defer { h.tearDown() }
        // No auth → provider.createRemoteTwin throws .unauthorized.
        h.authState.clear()
        let repo = BoardRepository(context: h.persistence.viewContext)
        let board = repo.createBoard(name: "Solo")
        try h.persistence.viewContext.save()
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: board.id!, boardName: "Solo")

        await model.createOnFizzy()

        #expect(model.actionError != nil)
        #expect(h.boardPairingStore.pairing(forLocal: board.id!) == nil)
    }

    @Test("linkExisting upserts the pairing with the chosen Fizzy id")
    func linkExistingPairs() async throws {
        let h = Harness(); defer { h.tearDown() }
        FizzyBoardBrowserOrchestrationTests.stubCreateAndEmptySync(
            h.mock, newID: "unused", name: "n/a")
        let repo = BoardRepository(context: h.persistence.viewContext)
        let board = repo.createBoard(name: "Roadmap")
        try h.persistence.viewContext.save()
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: board.id!, boardName: "Roadmap")

        await model.linkExisting(toFizzyBoardID: "fz-RDMP", fizzyBoardName: "Roadmap (Fizzy)")

        let pairing = try #require(h.boardPairingStore.pairing(forLocal: board.id!))
        #expect(pairing.fizzyBoardID == "fz-RDMP")
        #expect(pairing.fizzyBoardName == "Roadmap (Fizzy)")
        #expect(model.actionError == nil)
        #expect(model.lastLinkCollisions == nil)
    }

    @Test("loadUnpairedRemoteBoards returns remotes with no existing pairing")
    func loadUnpairedRemoteBoardsFiltersPaired() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.stubTwoRemoteBoards()   // returns fz-A and fz-B
        let repo = BoardRepository(context: h.persistence.viewContext)
        let alpha = repo.createBoard(name: "Alpha")
        try h.persistence.viewContext.save()
        h.boardPairingStore.upsert(FizzyBoardPairing(
            localBoardID: alpha.id!, fizzyBoardID: "fz-A"))
        let model = BoardFizzySyncModel(
            provider: h.provider, boardID: UUID(), boardName: "n/a")

        let unpaired = try await model.loadUnpairedRemoteBoards()

        #expect(unpaired.map(\.id) == ["fz-B"])
    }
}
