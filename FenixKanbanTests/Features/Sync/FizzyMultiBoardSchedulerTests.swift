import Testing
import Foundation
@testable import FenixKanban

@Suite("Fizzy multi-board scheduler order", .serialized)
@MainActor
struct FizzyMultiBoardSchedulerTests {

    @Test("frontmost board syncs first, then the rest in stored order")
    func frontmostFirst() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")
        let (c, _) = h.seedPairedBoard(name: "C", fizzyBoardID: "fz-C")

        h.provider.currentBoardID = b.id!                     // B is frontmost
        await h.provider.triggerSync(activityState: SyncActivityState())

        #expect(h.syncedBoardOrder == [b.id!, a.id!, c.id!])  // B first, then stored order
    }

    @Test("disabled boards are skipped")
    func skipsDisabled() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }
        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")
        h.pairingStore.setSyncEnabled(localBoardID: a.id!, false)

        await h.provider.triggerSync(activityState: SyncActivityState())
        #expect(h.syncedBoardOrder == [b.id!])
    }
}
