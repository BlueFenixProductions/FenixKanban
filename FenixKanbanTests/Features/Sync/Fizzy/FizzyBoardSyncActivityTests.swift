import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardSyncActivity")
@MainActor
struct FizzyBoardSyncActivityTests {

    @Test("unknown board defaults to idle")
    func defaultsIdle() {
        let activity = FizzyBoardSyncActivity()
        #expect(activity.phase(for: UUID()) == .idle)
    }

    @Test("transitions are per-board and independent")
    func perBoardTransitions() {
        let activity = FizzyBoardSyncActivity()
        let a = UUID(), b = UUID()
        activity.markSyncing(a)
        activity.markError(b, "boom")
        #expect(activity.phase(for: a) == .syncing)
        #expect(activity.phase(for: b) == .error("boom"))
        activity.markIdle(a)
        #expect(activity.phase(for: a) == .idle)
        #expect(activity.phase(for: b) == .error("boom"))   // b unaffected
    }
}

@Suite("FizzyBoardSyncActivity provider integration", .serialized)
@MainActor
struct FizzyBoardActivityProviderTests {

    @Test("successful round-robin marks each synced board idle")
    func roundRobinMarksIdle() async throws {
        let h = try MultiBoardHarness()
        defer { h.tearDown() }

        let (a, _) = h.seedPairedBoard(name: "A", fizzyBoardID: "fz-A")
        let (b, _) = h.seedPairedBoard(name: "B", fizzyBoardID: "fz-B")

        // Wrap the board-specific stubs with a handler that lets the engine
        // successfully push the local "Todo" column for each board. The real
        // Fizzy API uses 201 + Location → follow-up GET, so we must mirror
        // that two-step here; returning 200 triggers unexpectedStatus(200).
        let columnJSON = """
        {"id":"fc-todo","name":"Todo","color":{"name":"Slate","value":"var(--color-card-1)"},"created_at":"2026-06-26T00:00:00Z"}
        """
        let innerHandler = h.mock.handler
        h.mock.handler = { req in
            guard let url = req.url else {
                return (Data(), .response(for: req, status: 500))
            }
            let path = url.path
            // POST .../columns → 201 + Location (the column resource URL)
            if req.httpMethod == "POST", path.hasSuffix("/columns") {
                let location = url.absoluteString + "/fc-todo"
                return (Data(), .response(for: req, status: 201, headers: ["Location": location]))
            }
            // GET .../columns/fc-todo → the column body (follow-up from Location)
            if req.httpMethod == "GET", path.hasSuffix("/columns/fc-todo") {
                return (Data(columnJSON.utf8), .ok(for: req))
            }
            if let inner = innerHandler {
                return try inner(req)
            }
            return (Data(), .response(for: req, status: 500))
        }

        await h.provider.triggerSync(activityState: SyncActivityState())

        #expect(h.provider.boardActivityRef.phase(for: a.id!) == .idle)
        #expect(h.provider.boardActivityRef.phase(for: b.id!) == .idle)
    }
}
