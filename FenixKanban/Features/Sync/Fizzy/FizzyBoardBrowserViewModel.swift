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

    init(provider: FizzySyncProvider) {
        self.provider = provider
    }

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
