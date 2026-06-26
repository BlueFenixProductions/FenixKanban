import Foundation
import CoreData
import Observation

/// Drives `FizzyBoardBrowserView` (issue #18, Phase 7b). Loads the three
/// reconciliation inputs — local `Board` set, remote board list, pairing store —
/// and rebuilds `rows` via `BoardBrowserRow.reconcile`. Holds no pairing state
/// of its own; `refreshFromStore()` rebuilds after a local mutation without a
/// network round-trip.
@Observable
@MainActor
final class FizzyBoardBrowserViewModel {

    enum LoadState: Equatable {
        case loading
        case loaded
        case error(String)
    }

    private let provider: FizzySyncProvider

    private(set) var state: LoadState = .loading
    private(set) var rows: [BoardBrowserRow] = []
    private(set) var remoteBoards: [RemoteBoard] = []
    private(set) var actionError: String?
    private(set) var lastLinkCollisions: [String]?

    init(provider: FizzySyncProvider) {
        self.provider = provider
    }

    /// Remote boards with no pairing yet — the candidates a "Local only" board
    /// can link to. Drives the Link picker.
    var unpairedRemoteBoards: [RemoteBoard] {
        remoteBoards.filter { provider.boardPairingStoreRef.pairing(forFizzy: $0.id) == nil }
    }

    /// Test seam: set the cached remote list without a network fetch.
    func seedRemoteBoardsForTesting(_ boards: [RemoteBoard]) { remoteBoards = boards }

    /// Fetches local + remote boards, then rebuilds rows. On remote failure the
    /// state goes `.error` but paired + local-only rows still render from cached
    /// store data (a degraded but useful list).
    func load() async {
        state = .loading
        do {
            remoteBoards = try await provider.fetchRemoteBoards()
            rebuildRows()
            state = .loaded
        } catch {
            remoteBoards = []
            rebuildRows()
            state = .error("\(error)")
        }
    }

    /// Rebuilds rows from the current store + cached remote list, with no
    /// network call — used after toggle / unpair so the UI updates immediately.
    func refreshFromStore() {
        rebuildRows()
    }

    /// Flips `syncEnabled` for a paired row (pause / resume), then reprojects.
    func toggleSync(_ row: BoardBrowserRow) {
        guard row.kind == .paired, let id = row.localBoardID else { return }
        provider.setSyncEnabled(localBoardID: id, !row.syncEnabled)
        rebuildRows()
    }

    /// Removes the pairing for a paired row (never touches `Card` data), then
    /// reprojects — the board reappears as a local-only row.
    func unpair(_ row: BoardBrowserRow) {
        guard row.kind == .paired, let id = row.localBoardID else { return }
        provider.unpair(localBoardID: id)
        rebuildRows()
    }

    /// Runs a one-board sync. Errors are swallowed here; the per-board activity
    /// registry (`provider.boardActivityRef`) records them for the row to show.
    func syncNow(_ row: BoardBrowserRow) async {
        guard row.kind == .paired, row.syncEnabled,
              let id = row.localBoardID, let fizzyID = row.fizzyBoardID else { return }
        _ = try? await provider.sync(boardId: id, remoteProjectId: fizzyID)
        rebuildRows()
    }

    /// Create-on-Fizzy: make a remote twin of a local-only board (named after
    /// the local board) and push. Reprojects to a paired row on success.
    func createOnFizzy(_ row: BoardBrowserRow) async {
        actionError = nil
        lastLinkCollisions = nil
        guard row.kind == .localOnly, let id = row.localBoardID else { return }
        do {
            _ = try await provider.createRemoteTwin(localBoardID: id, name: row.title)
        } catch {
            actionError = "Couldn't create the board on Fizzy: \(error)"
        }
        rebuildRows()
    }

    /// Add-to-FK: create a local board from a remote-only board and replace-pull.
    func addToFK(_ row: BoardBrowserRow) async {
        actionError = nil
        lastLinkCollisions = nil
        guard row.kind == .remoteOnly, let fizzyID = row.fizzyBoardID else { return }
        do {
            _ = try await provider.addToFK(fizzyBoardID: fizzyID, name: row.title)
        } catch {
            actionError = "Couldn't add the board to FenixKanban: \(error)"
        }
        rebuildRows()
    }

    /// Link-existing: merge a local-only board with a chosen unpaired remote
    /// board. Same-title collisions (returned in `result.errors`) are exposed
    /// via `lastLinkCollisions` for the view to show.
    func linkExisting(_ localRow: BoardBrowserRow, toFizzyBoardID fizzyID: String, fizzyBoardName: String?) async {
        actionError = nil
        lastLinkCollisions = nil
        guard localRow.kind == .localOnly, let id = localRow.localBoardID else { return }
        do {
            let result = try await provider.linkExisting(
                localBoardID: id, fizzyBoardID: fizzyID, fizzyBoardName: fizzyBoardName)
            if !result.errors.isEmpty { lastLinkCollisions = result.errors }
        } catch {
            actionError = "Couldn't link the boards: \(error)"
        }
        rebuildRows()
    }

    func dismissActionError() { actionError = nil }
    func dismissLinkCollisions() { lastLinkCollisions = nil }

    private func rebuildRows() {
        rows = BoardBrowserRow.reconcile(
            localBoards: fetchLocalBoards(),
            remoteBoards: remoteBoards,
            pairings: provider.boardPairingStoreRef.all()
        )
    }

    private func fetchLocalBoards() -> [BoardBrowserRow.LocalBoardInfo] {
        let request: NSFetchRequest<Board> = Board.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        let boards = (try? provider.persistenceRef.viewContext.fetch(request)) ?? []
        return boards.compactMap { b in
            guard let id = b.id else { return nil }
            return BoardBrowserRow.LocalBoardInfo(id: id, name: b.name ?? "(untitled)")
        }
    }
}
