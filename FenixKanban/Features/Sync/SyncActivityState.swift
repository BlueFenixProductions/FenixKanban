import Foundation
import Observation

/// Observable sync activity state published by `SyncScheduler`.
///
/// Views observe this object to show last-sync timestamp, in-progress
/// spinner, and last error line. Uses `@Observable` (not `ObservableObject`)
/// per project conventions.
@Observable
@MainActor
final class SyncActivityState {

    /// Lifecycle phase of the most recent sync attempt.
    enum Phase: Equatable {
        case idle
        case syncing
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.syncing, .syncing): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    var phase: Phase = .idle
    /// Timestamp of the most recent successfully completed sync.
    var lastSyncAt: Date?
    /// The last error message, preserved across subsequent idle transitions.
    var lastError: String?
    /// Number of local push operations that failed in the last cycle
    /// (cards with local edits that could not be sent to the server).
    var pendingPushCount: Int = 0
    /// Number of open LWW conflicts requiring user resolution.
    var conflictCount: Int = 0

    func markSyncing() {
        phase = .syncing
    }

    func markIdle(syncedAt: Date?) {
        phase = .idle
        if let syncedAt {
            lastSyncAt = syncedAt
        }
        lastError = nil
    }

    func markError(_ message: String) {
        phase = .error(message)
        lastError = message
    }

    /// Updates derived counts from a completed sync result and the conflict store.
    /// `lastSyncAt` is advanced unconditionally (the cycle ran; the badge is separate).
    func update(from result: FizzySyncResult, conflictStore: FizzyConflictStore) {
        pendingPushCount = result.errors.filter { $0.hasPrefix("Push update") }.count
        conflictCount = conflictStore.count
    }
}
