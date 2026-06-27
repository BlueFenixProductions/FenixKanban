import Foundation
import Observation

/// Per-board transient sync activity, keyed by local board UUID (issue #18,
/// Phase 7b). The board browser observes this so each row can show an
/// in-progress spinner or an error line independently of the others. Reuses
/// `SyncActivityState.Phase` (Phase 6) as the per-board lifecycle; a board with
/// no recorded entry reads as `.idle`.
@Observable
@MainActor
final class FizzyBoardSyncActivity {

    private(set) var phases: [UUID: SyncActivityState.Phase] = [:]

    func phase(for boardID: UUID) -> SyncActivityState.Phase {
        phases[boardID] ?? .idle
    }

    func markSyncing(_ boardID: UUID) { phases[boardID] = .syncing }
    func markIdle(_ boardID: UUID) { phases[boardID] = .idle }
    func markError(_ boardID: UUID, _ message: String) { phases[boardID] = .error(message) }
}
