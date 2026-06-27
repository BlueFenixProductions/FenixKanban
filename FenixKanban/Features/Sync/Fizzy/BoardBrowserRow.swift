import Foundation

/// One row in the board browser, reconciling the local `Board` set, the remote
/// board list, and the device-local pairing store (issue #18, Phase 7b).
///
/// A pure value snapshot — it holds no live CoreData object. Display fields are
/// captured at reconcile time so the list is a stateless projection that cannot
/// drift from the stores.
struct BoardBrowserRow: Identifiable, Equatable {

    enum Kind: Equatable {
        case paired       // a pairing exists for this board
        case localOnly    // a local board with no pairing
        case remoteOnly   // a remote board with no pairing
    }

    /// Stable identity: the local board UUID string for paired/local rows,
    /// `"fizzy:<id>"` for remote-only rows.
    let id: String
    let kind: Kind
    let localBoardID: UUID?
    let fizzyBoardID: String?
    let title: String
    let lastSyncAt: Date?
    let syncEnabled: Bool

    /// Minimal local-board projection so the join is unit-testable without
    /// spinning up CoreData.
    struct LocalBoardInfo: Equatable {
        let id: UUID
        let name: String
    }

    /// The reconciliation join (Phase 7b). Returns rows grouped by kind:
    /// paired first (in pairing-store insertion order), then local-only, then
    /// remote-only. A paired row's title prefers the resolved local board name,
    /// then the cached `fizzyBoardName`, then the live remote name.
    static func reconcile(
        localBoards: [LocalBoardInfo],
        remoteBoards: [RemoteBoard],
        pairings: [FizzyBoardPairing]
    ) -> [BoardBrowserRow] {
        let localByID = Dictionary(localBoards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remoteBoards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairedLocalIDs = Set(pairings.map(\.localBoardID))
        let pairedFizzyIDs = Set(pairings.map(\.fizzyBoardID))

        let pairedRows = pairings.map { p in
            BoardBrowserRow(
                id: p.localBoardID.uuidString,
                kind: .paired,
                localBoardID: p.localBoardID,
                fizzyBoardID: p.fizzyBoardID,
                title: localByID[p.localBoardID]?.name
                    ?? p.fizzyBoardName
                    ?? remoteByID[p.fizzyBoardID]?.name
                    ?? "(unknown board)",
                lastSyncAt: p.lastSyncAt,
                syncEnabled: p.syncEnabled
            )
        }

        let localOnlyRows = localBoards
            .filter { !pairedLocalIDs.contains($0.id) }
            .map { l in
                BoardBrowserRow(
                    id: l.id.uuidString,
                    kind: .localOnly,
                    localBoardID: l.id,
                    fizzyBoardID: nil,
                    title: l.name,
                    lastSyncAt: nil,
                    syncEnabled: false
                )
            }

        let remoteOnlyRows = remoteBoards
            .filter { !pairedFizzyIDs.contains($0.id) }
            .map { r in
                BoardBrowserRow(
                    id: "fizzy:\(r.id)",
                    kind: .remoteOnly,
                    localBoardID: nil,
                    fizzyBoardID: r.id,
                    title: r.name,
                    lastSyncAt: nil,
                    syncEnabled: false
                )
            }

        return pairedRows + localOnlyRows + remoteOnlyRows
    }
}
