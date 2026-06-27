import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardBrowser orchestration", .serialized)
@MainActor
struct FizzyBoardBrowserOrchestrationTests {

    typealias Harness = FizzyBoardBrowserViewModelTests.Harness

    /// Stubs board creation (POST → 201+Location, GET detail) and makes every
    /// other GET return an empty JSON array and every write a 201 — so a
    /// first-sync over an empty board completes without throwing.
    static func stubCreateAndEmptySync(_ mock: MockHTTPState, newID: String, name: String) {
        let detail = """
        {"id":"\(newID)","name":"\(name)","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":null,"creator":{"id":"U1","name":"C","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
        """
        mock.handler = { req in
            let path = req.url?.path ?? ""
            switch req.httpMethod {
            case "POST" where path.hasSuffix("/boards"):
                return (Data(), .response(for: req, status: 201,
                    headers: ["Location": "https://example.com/ACCT/boards/\(newID)"]))
            case "GET" where path.hasSuffix("/boards/\(newID)"):
                return (detail.data(using: .utf8)!, .ok(for: req))
            case "GET":
                return ("[]".data(using: .utf8)!, .ok(for: req))   // list / columns / cards
            default:
                return ("{}".data(using: .utf8)!, .response(for: req, status: 201))
            }
        }
    }

    @Test("createRemoteTwin POSTs a board, caches the name, and upserts a pairing")
    func createRemoteTwinPairs() async throws {
        let h = Harness(); defer { h.tearDown() }
        Self.stubCreateAndEmptySync(h.mock, newID: "fz-NEW", name: "Personal")

        let repo = BoardRepository(context: h.persistence.viewContext)
        let local = repo.createBoard(name: "Personal")
        try h.persistence.viewContext.save()

        _ = try await h.provider.createRemoteTwin(localBoardID: local.id!, name: "Personal")

        let pairing = try #require(h.boardPairingStore.pairing(forLocal: local.id!))
        #expect(pairing.fizzyBoardID == "fz-NEW")
        #expect(pairing.fizzyBoardName == "Personal")
        #expect(h.mock.requests.contains { $0.httpMethod == "POST" && ($0.url?.path.hasSuffix("/boards") ?? false) })
    }

    @Test("addToFK creates a local board, returns its id, and upserts a pairing")
    func addToFKCreatesLocalBoard() async throws {
        let h = Harness(); defer { h.tearDown() }
        Self.stubCreateAndEmptySync(h.mock, newID: "unused", name: "Design Review")

        let newLocalID = try await h.provider.addToFK(fizzyBoardID: "fz-REMOTE", name: "Design Review")

        let boards = try h.persistence.viewContext.fetch(Board.fetchRequest()) as [Board]
        #expect(boards.contains { $0.id == newLocalID && $0.name == "Design Review" })
        let pairing = try #require(h.boardPairingStore.pairing(forLocal: newLocalID))
        #expect(pairing.fizzyBoardID == "fz-REMOTE")
    }

    @Test("linkExisting pairs the two boards and runs a merge first-sync")
    func linkExistingPairsAndMerges() async throws {
        let h = Harness(); defer { h.tearDown() }
        Self.stubCreateAndEmptySync(h.mock, newID: "unused", name: "n/a")

        let repo = BoardRepository(context: h.persistence.viewContext)
        let local = repo.createBoard(name: "Roadmap")
        try h.persistence.viewContext.save()

        let result = try await h.provider.linkExisting(
            localBoardID: local.id!, fizzyBoardID: "fz-RDMP", fizzyBoardName: "Roadmap (Fizzy)")

        let pairing = try #require(h.boardPairingStore.pairing(forLocal: local.id!))
        #expect(pairing.fizzyBoardID == "fz-RDMP")
        #expect(pairing.fizzyBoardName == "Roadmap (Fizzy)")
        // Empty boards → merge produces no collision errors.
        #expect(result.errors.isEmpty)
    }
}
