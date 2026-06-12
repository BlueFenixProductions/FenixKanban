import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Task #50 — Milestone A acceptance: restore the Playground board.
///
/// Hits the REAL Fizzy server (env-gated; skips without credentials; never
/// runs in CI). Logically read-only against the board: a fresh local board
/// with no columns and no cards has nothing to push, replace-local only
/// pulls, and the steady-state second pass asserts zero deltas — the
/// anti-duplicate invariant that historically poisoned this board.
///
/// `FIZZY_EXPECTED_CARDS` (default 32) pins the genuine card count; the
/// expected column for all of them after the 2026-06-12 cleanup is "Ready".
@Suite("Live: playground restore", .enabled(if: LiveTestEnv.isConfigured), .serialized)
@MainActor
struct LivePlaygroundRestoreTests {

    @Test("replaceLocal pulls the full playground board; second sync is a no-op")
    func restoresPlaygroundAndStaysStable() async throws {
        let client = LiveTestEnv.makeClient()

        // Resolve the playground board by name — never create boards here.
        let boards = try await client.boards()
        let playground = try #require(
            boards.first { $0.name.lowercased() == "playground" },
            "live account must contain a board named Playground; found: \(boards.map(\.name))"
        )

        // Fresh, isolated local world.
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let boardRepo = BoardRepository(context: persistence.viewContext)
        let board = boardRepo.createBoard(name: "FenixKanban")
        try persistence.viewContext.save()

        let suiteName = "test.fizzy.live.restore.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: playground.id)

        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-live-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }

        let authState = FizzyAuthState(keyPrefix: "test.fizzy.live.\(UUID().uuidString)")
        defer { authState.clear() }
        authState.setAccessToken(LiveTestEnv.token)
        authState.setAccountSlug(LiveTestEnv.accountSlug)

        let engine = FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: persistence.viewContext,
            pairingStore: pairingStore
        )

        // Act 1 — the restore.
        let restore = try await engine.syncFirst(mode: .replaceLocalWithFizzy)
        #expect(restore.errors.isEmpty, "restore errors: \(restore.errors)")
        #expect(restore.itemsCreated == LiveTestEnv.expectedCards)

        let columns: [Column] = (board.columns as? Set<Column>).map { Array($0) } ?? []
        let cards: [Card] = columns.flatMap { (($0.cards as? Set<Card>).map { Array($0) }) ?? [] }
        #expect(cards.count == LiveTestEnv.expectedCards,
                "expected \(LiveTestEnv.expectedCards) cards, got \(cards.count)")

        // Post-cleanup state: every card lives in "Ready", and the remote
        // columns (Ready / In Progress / Done) exist locally with IDs claimed.
        let ready = try #require(columns.first { $0.name == "Ready" })
        #expect(((ready.cards as? Set<Card>) ?? []).count == LiveTestEnv.expectedCards)
        #expect(columns.allSatisfy { $0.fizzyColumnID != nil })

        // Every card is paired in the device-local store.
        let unpaired = cards.filter { $0.id.flatMap { pairingStore.pairing(for: $0) } == nil }
        #expect(unpaired.isEmpty, "unpaired after restore: \(unpaired.compactMap(\.title))")

        // Act 2 — the anti-duplicate invariant: an immediate steady-state
        // cycle must change nothing, locally or remotely.
        let second = try await engine.sync()
        #expect(second.errors.isEmpty, "second sync errors: \(second.errors)")
        #expect(second.itemsCreated == 0, "second sync must create nothing")
        #expect(second.itemsDeleted == 0, "second sync must delete nothing")

        let after: [Card] = columns.flatMap { (($0.cards as? Set<Card>).map { Array($0) }) ?? [] }
        #expect(after.count == LiveTestEnv.expectedCards)
    }
}
