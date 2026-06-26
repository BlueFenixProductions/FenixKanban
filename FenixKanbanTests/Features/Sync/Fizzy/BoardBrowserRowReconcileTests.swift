import Testing
import Foundation
@testable import FenixKanban

@Suite("BoardBrowserRow.reconcile")
struct BoardBrowserRowReconcileTests {

    private func remote(_ id: String, _ name: String) -> RemoteBoard {
        RemoteBoard(id: id, name: name, provider: "Fizzy")
    }

    @Test("each of the four cases lands in the right kind, paired first")
    func fourCases() {
        let localPaired = UUID()
        let localOnly = UUID()

        let rows = BoardBrowserRow.reconcile(
            localBoards: [
                .init(id: localPaired, name: "Roadmap"),
                .init(id: localOnly, name: "Personal"),
            ],
            remoteBoards: [
                remote("fz-roadmap", "Roadmap"),
                remote("fz-design", "Design Review"),
            ],
            pairings: [
                FizzyBoardPairing(localBoardID: localPaired, fizzyBoardID: "fz-roadmap",
                                  lastSyncAt: Date(timeIntervalSince1970: 100), syncEnabled: true)
            ]
        )

        #expect(rows.count == 3)
        // Paired row first.
        #expect(rows[0].kind == .paired)
        #expect(rows[0].localBoardID == localPaired)
        #expect(rows[0].fizzyBoardID == "fz-roadmap")
        #expect(rows[0].title == "Roadmap")
        #expect(rows[0].lastSyncAt == Date(timeIntervalSince1970: 100))
        #expect(rows[0].syncEnabled == true)
        // Then local-only.
        #expect(rows[1].kind == .localOnly)
        #expect(rows[1].localBoardID == localOnly)
        #expect(rows[1].title == "Personal")
        // Then remote-only.
        #expect(rows[2].kind == .remoteOnly)
        #expect(rows[2].fizzyBoardID == "fz-design")
        #expect(rows[2].title == "Design Review")
    }

    @Test("paused pairing carries syncEnabled == false")
    func pausedPairing() {
        let id = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [.init(id: id, name: "Archive")],
            remoteBoards: [remote("fz-archive", "Archive")],
            pairings: [FizzyBoardPairing(localBoardID: id, fizzyBoardID: "fz-archive", syncEnabled: false)]
        )
        #expect(rows.count == 1)
        #expect(rows[0].kind == .paired)
        #expect(rows[0].syncEnabled == false)
    }

    @Test("title falls back to cached fizzyBoardName then remote name when local missing")
    func titleFallback() {
        let missingLocal = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [],
            remoteBoards: [remote("fz-x", "Remote Name")],
            pairings: [FizzyBoardPairing(localBoardID: missingLocal, fizzyBoardID: "fz-x",
                                         fizzyBoardName: "Cached Name")]
        )
        #expect(rows[0].title == "Cached Name")
    }

    @Test("ids are stable and unique across kinds")
    func stableIDs() {
        let local = UUID()
        let rows = BoardBrowserRow.reconcile(
            localBoards: [.init(id: local, name: "L")],
            remoteBoards: [remote("fz-r", "R")],
            pairings: []
        )
        #expect(rows.first { $0.kind == .localOnly }?.id == local.uuidString)
        #expect(rows.first { $0.kind == .remoteOnly }?.id == "fizzy:fz-r")
    }
}
