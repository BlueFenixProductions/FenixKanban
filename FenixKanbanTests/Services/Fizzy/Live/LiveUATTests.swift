import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Constants

private let sandboxBoardID = "03gankdglgg6jr6k6g0jsv04m"
private let iTestPrefix = "[itest]"

// MARK: - Item 5 note
//
// UAT Item 5 (replace mode — .replaceLocalWithFizzy) is covered by
// LivePlaygroundRestoreTests (FenixKanbanTests/Services/Fizzy/Live/).
// It verifies the first-sync replace path end-to-end against the live server.

// MARK: - Item 6: 401 recovery (read-only — no mutation gate)

/// UAT Item 6: engine with a garbage token must throw FizzyError.unauthorized
/// and the injected FizzyAuthState must be cleared afterwards.
/// Pure read; no Sandbox-2 mutation — gated only on isConfigured.
@Suite("Live: UAT Item 6 — 401 recovery", .enabled(if: LiveTestEnv.isConfigured), .serialized)
@MainActor
struct LiveUAT401RecoveryTests {

    @Test("garbage-token sync throws .unauthorized and clears authState")
    func garbageTokenClearsAuthState() async throws {
        // Isolated auth state with a garbage token.
        // useKeychain: false — clone simulators used by xcodebuild live-tests
        // don't have an active Keychain session; in-memory storage avoids the
        // silent write failure that would cause isConfigured to return false.
        let prefix = "test.uat6.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix, useKeychain: false)
        authState.setAccessToken("garbage-token-intentionally-invalid")
        authState.setAccountSlug(LiveTestEnv.accountSlug)
        defer { authState.clear() }

        // Isolated mapping with a fake pairing (sandbox board).
        let suiteName = "test.uat6.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }

        // In-memory persistence so we never touch the user's real store.
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let context = persistence.viewContext

        // Create a local board and pair it to the sandbox (engine won't sync
        // without a pairing even if it 401s on the first request).
        let board = BoardRepository(context: context).createBoard(name: "UAT6 Board")
        try context.save()
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: sandboxBoardID)

        // Isolated pairing store.
        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-uat6-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }

        // Verify Keychain writes succeeded before proceeding — a silent write
        // failure would cause the engine to return early (isConfigured guard)
        // without ever hitting the network, giving a false pass on the
        // post-sync authState.clear() assertions.
        try #require(authState.isConfigured,
            "Keychain write failed — cannot test 401 recovery without a configured authState")

        // Live client with garbage token pointed at real base URL.
        let client = FizzyClient(
            baseURL: LiveTestEnv.baseURL,
            accessToken: "garbage-token-intentionally-invalid",
            accountSlug: LiveTestEnv.accountSlug
        )

        let engine = FizzySyncEngine(
            client: client,
            authState: authState,
            mapping: mapping,
            context: context,
            pairingStore: pairingStore
        )

        // The sync must throw .unauthorized.
        do {
            _ = try await engine.sync()
            Issue.record("Expected FizzyError.unauthorized — engine must throw on 401")
        } catch FizzyError.unauthorized {
            // Expected path.
        } catch {
            Issue.record("Expected FizzyError.unauthorized but got: \(error)")
        }

        // After the throw, authState must be cleared (token + slug gone).
        #expect(authState.accessToken == nil,
            "FizzySyncEngine.sync() must clear authState on 401")
        #expect(authState.accountSlug == nil,
            "FizzySyncEngine.sync() must clear authState slug on 401")
    }
}

// MARK: - Items 4 & 7: mutation suites

/// UAT Items 4 and 7 — exercised against the Sandbox-2 board with
/// [itest]-prefixed sacrificial cards, cleaned up in defer blocks.
/// Gated on both isConfigured and allowsMutation.
@Suite("Live: UAT Item 4 — pull golden flag", .enabled(if: LiveTestEnv.isConfigured), .serialized)
@MainActor
struct LiveUATPullGoldenTests {

    // MARK: - Item 4: golden flag pulled from remote

    @Test("create card, mark golden remotely, syncFirst replaceLocal → isGolden == true locally",
          .enabled(if: LiveTestEnv.isConfigured && LiveTestEnv.allowsMutation))
    func pullGoldenFlagFromRemote() async throws {
        let client = LiveTestEnv.makeClient()

        // --- Remote setup ---
        // 1. Get the first column of Sandbox-2 (for triage).
        let columns = try await client.getAllPages(
            "/boards/\(sandboxBoardID)/columns",
            as: [FizzyColumn].self
        )
        let column = try #require(columns.first, "Sandbox-2 must have at least one column")

        // 2. Create a sacrificial card.
        let cardTitle = "\(iTestPrefix) golden \(UUID().uuidString)"
        let created: FizzyCard = try await client.post(
            "/boards/\(sandboxBoardID)/cards",
            body: FizzyCardWritePayload(card: FizzyCardWrite(title: cardTitle)),
            as: FizzyCard.self
        )
        defer {
            // Best-effort cleanup — DELETE even if the test fails.
            Task {
                try? await client.deleteCard(number: created.number)
            }
        }

        // 3. Triage the card into the first column (new cards start untriaged
        //    per fizzy-api-notes.md).
        try await client.triageCard(number: created.number, columnID: column.id)

        // 4. Mark the card golden via the goldness endpoint.
        try await client.markCardGolden(number: created.number)

        // --- Local sync setup ---
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let context = persistence.viewContext

        let prefix = "test.uat4.\(UUID().uuidString)"
        // useKeychain: false — see Item 6 comment above.
        let authState = FizzyAuthState(keyPrefix: prefix, useKeychain: false)
        authState.setAccessToken(LiveTestEnv.token)
        authState.setAccountSlug(LiveTestEnv.accountSlug)
        defer { authState.clear() }

        let suiteName = "test.uat4.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }

        // Create a local board and pair it to Sandbox-2.
        let localBoard = BoardRepository(context: context).createBoard(name: "UAT4 Board")
        try context.save()
        mapping.setPairing(localBoardID: localBoard.id!, fizzyBoardID: sandboxBoardID)

        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-uat4-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }

        // Guard: Keychain write must succeed before syncFirst.
        try #require(authState.isConfigured,
            "Keychain write failed — cannot test golden-flag pull without a configured authState")

        let liveClient = LiveTestEnv.makeClient()
        let engine = FizzySyncEngine(
            client: liveClient,
            authState: authState,
            mapping: mapping,
            context: context,
            pairingStore: pairingStore
        )

        // 5. First-sync in replace mode (pulls remote → local).
        let result = try await engine.syncFirst(mode: .replaceLocalWithFizzy)
        #expect(result.errors.isEmpty, "syncFirst must produce no errors: \(result.errors)")

        // 6. Find the local card that corresponds to the newly golden remote card.
        let cardRequest: NSFetchRequest<Card> = Card.fetchRequest()
        cardRequest.predicate = NSPredicate(format: "title == %@", cardTitle)
        let localCards = try context.fetch(cardRequest)
        let localCard = try #require(localCards.first, "Local card '\(cardTitle)' must exist after replaceLocal sync")

        // 7. Assert the local card is golden.
        #expect(localCard.isGolden == true, "Card pulled from Fizzy with golden=true must have isGolden==true locally")
    }
}

@Suite("Live: UAT Item 7 — re-pair merge, zero remote creates", .enabled(if: LiveTestEnv.isConfigured), .serialized)
@MainActor
struct LiveUATRePairMergeTests {

    // MARK: - Item 7: sign-out → re-pair → merge creates no remote duplicates

    @Test("re-pair after board-mapping clear: mergeIfNoConflicts creates zero remote cards",
          .enabled(if: LiveTestEnv.isConfigured && LiveTestEnv.allowsMutation))
    func rePairMergeCreatesNoRemoteCards() async throws {
        let client = LiveTestEnv.makeClient()

        // --- Measure baseline remote card count on Sandbox-2 ---
        let columnsBefore = try await client.getAllPages(
            "/boards/\(sandboxBoardID)/columns",
            as: [FizzyColumn].self
        )
        var remoteCountBefore = 0
        for col in columnsBefore {
            let cards = try await client.getAllPages(
                "/boards/\(sandboxBoardID)/columns/\(col.id)/cards",
                as: [FizzyCard].self
            )
            remoteCountBefore += cards.count
        }

        // --- Setup: first sync (replaceLocal) to get a paired local world ---
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let context = persistence.viewContext

        let prefix = "test.uat7.\(UUID().uuidString)"
        // useKeychain: false — see Item 6 comment above.
        let authState = FizzyAuthState(keyPrefix: prefix, useKeychain: false)
        authState.setAccessToken(LiveTestEnv.token)
        authState.setAccountSlug(LiveTestEnv.accountSlug)
        defer { authState.clear() }

        let suiteName = "test.uat7.mapping.\(UUID().uuidString)"
        let mappingDefaults = UserDefaults(suiteName: suiteName)!
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        defer { mappingDefaults.removePersistentDomain(forName: suiteName) }

        let pairingStore = FizzyCardPairingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fk-uat7-pairings-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: pairingStore.fileURL) }

        // Guard: Keychain write must succeed before syncFirst.
        try #require(authState.isConfigured,
            "Keychain write failed — cannot test re-pair merge without a configured authState")

        let localBoard = BoardRepository(context: context).createBoard(name: "UAT7 Board")
        try context.save()
        mapping.setPairing(localBoardID: localBoard.id!, fizzyBoardID: sandboxBoardID)

        let engine = FizzySyncEngine(
            client: LiveTestEnv.makeClient(),
            authState: authState,
            mapping: mapping,
            context: context,
            pairingStore: pairingStore
        )

        // First sync: pull Sandbox-2 → local.
        let firstResult = try await engine.syncFirst(mode: .replaceLocalWithFizzy)
        #expect(firstResult.errors.isEmpty, "Initial replaceLocal must succeed: \(firstResult.errors)")

        // --- Simulate signOut's board-mapping clear (FizzySyncProvider.changePairing) ---
        // Per FizzySyncProvider.changePairing: clear the mapping but keep the
        // Keychain token (re-pairing must never cost the token).
        mapping.clear()
        // Pairing store: keep (the engine re-seeds from store on next sync).

        // --- Re-pair to the same Sandbox-2 board ---
        mapping.setPairing(localBoardID: localBoard.id!, fizzyBoardID: sandboxBoardID)

        // Fresh engine instance (provider rebuilds it on re-pair, matching
        // FizzySyncProvider.makeEngine() semantics).
        let engine2 = FizzySyncEngine(
            client: LiveTestEnv.makeClient(),
            authState: authState,
            mapping: mapping,
            context: context,
            pairingStore: pairingStore
        )

        // Re-pair sync in merge mode.
        let mergeResult = try await engine2.syncFirst(mode: .mergeIfNoConflicts)
        #expect(mergeResult.errors.isEmpty, "Merge after re-pair must succeed: \(mergeResult.errors)")

        // --- Verify: zero cards CREATED on Sandbox-2 ---
        let columnsAfter = try await client.getAllPages(
            "/boards/\(sandboxBoardID)/columns",
            as: [FizzyColumn].self
        )
        var remoteCountAfter = 0
        for col in columnsAfter {
            let cards = try await client.getAllPages(
                "/boards/\(sandboxBoardID)/columns/\(col.id)/cards",
                as: [FizzyCard].self
            )
            remoteCountAfter += cards.count
        }
        #expect(
            remoteCountAfter == remoteCountBefore,
            "Re-pair merge must create zero remote cards: before=\(remoteCountBefore) after=\(remoteCountAfter)"
        )

        // --- Verify: no local duplicates ---
        // Card has no direct `board` relationship — traverse via column.board.
        let cardRequest: NSFetchRequest<Card> = Card.fetchRequest()
        cardRequest.predicate = NSPredicate(format: "column.board == %@", localBoard)
        let allLocalCards = try context.fetch(cardRequest)
        let titleCounts = Dictionary(grouping: allLocalCards, by: { $0.title ?? "" })
        let duplicates = titleCounts.filter { $0.value.count > 1 }.keys
        #expect(
            duplicates.isEmpty,
            "Re-pair merge must not create local duplicates: \(Array(duplicates))"
        )
    }
}
