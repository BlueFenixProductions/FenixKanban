import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("FizzySyncProvider", .serialized)
@MainActor
struct FizzySyncProviderTests {

    /// Builds an in-memory persistence + isolated auth/mapping suite
    /// + MockURLProtocol-backed FizzyClient. Returns a configured provider
    /// for the test to exercise.
    private struct Harness {
        let mock = MockHTTPState()
        let persistence: PersistenceController
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let suiteName: String
        let pairingStore: FizzyCardPairingStore
        let provider: FizzySyncProvider

        @MainActor
        init() {
            persistence = PersistenceController(inMemory: true, useCloudKit: false)

            let prefix = "test.fizzy.provider.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)

            suiteName = "test.fizzy.provider.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)

            let session = mock.makeSession()

            // Temp-file pairing store — the provider's engines must never
            // write the developer's real Application Support sidecar.
            pairingStore = FizzyCardPairingStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("fk-pairings-\(UUID().uuidString).json")
            )

            provider = FizzySyncProvider(
                authState: authState,
                mapping: mapping,
                persistence: persistence,
                urlSession: session,
                clock: ImmediateClock(),
                pairingStore: pairingStore
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: pairingStore.fileURL)
        }
    }

    @Test("providerName is 'Fizzy'")
    func providerNameMatchesSpec() {
        let h = Harness(); defer { h.tearDown() }
        #expect(h.provider.providerName == "Fizzy")
    }

    @Test("isAuthenticated mirrors authState.isConfigured")
    func isAuthenticatedMirrorsAuthState() {
        let h = Harness(); defer { h.tearDown() }
        #expect(h.provider.isAuthenticated == false)

        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")
        #expect(h.provider.isAuthenticated == true)

        h.authState.clear()
        #expect(h.provider.isAuthenticated == false)
    }

    @Test("authenticate() throws requiresInteractiveAuth — UI must open FizzyAuthView")
    func authenticateThrowsInteractiveSignal() async {
        let h = Harness(); defer { h.tearDown() }
        do {
            try await h.provider.authenticate()
            Issue.record("expected authenticate() to throw")
        } catch let error as FizzyError {
            #expect(error == .requiresInteractiveAuth)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("signOut clears authState and mapping but keeps local Cards")
    func signOutClearsAuthAndMappingNoCards() async throws {
        let h = Harness(); defer { h.tearDown() }

        // Build a paired board with cards on both the paired and a non-paired board.
        let boardRepo = BoardRepository(context: h.persistence.viewContext)
        let cardRepo = CardRepository(context: h.persistence.viewContext)
        let paired = boardRepo.createBoard(name: "Paired")
        let pairedCol = boardRepo.createColumn(in: paired, name: "C")
        _ = cardRepo.createCard(in: pairedCol, title: "kept-1")
        _ = cardRepo.createCard(in: pairedCol, title: "kept-2")

        let other = boardRepo.createBoard(name: "Other")
        let otherCol = boardRepo.createColumn(in: other, name: "C")
        _ = cardRepo.createCard(in: otherCol, title: "kept-3")

        try h.persistence.viewContext.save()

        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")
        let mapping = FizzyBoardMapping(defaults: h.mappingDefaults)
        mapping.setPairing(localBoardID: paired.id!, fizzyBoardID: "FB1")
        mapping.setLastSync(.now)

        try await h.provider.signOut()

        #expect(h.authState.accessToken == nil)
        #expect(h.authState.accountSlug == nil)
        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)

        // Cards on both boards still present.
        let cardRequest: NSFetchRequest<Card> = Card.fetchRequest()
        let allCards = try h.persistence.viewContext.fetch(cardRequest)
        #expect(allCards.count == 3)
    }

    @Test("fetchRemoteBoards maps FizzyBoard JSON to RemoteBoard")
    func fetchRemoteBoardsMapsDTOs() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok"); h.authState.setAccountSlug("ACCT")

        let json = """
        [
          {"id":"FB1","name":"Public Roadmap","all_access":true,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":7,"url":"https://fizzy.bluefenix.net/ACCT/boards/FB1","creator":{"id":"U1","name":"Chris","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}},
          {"id":"FB2","name":"Private","all_access":false,"created_at":"2026-05-25T00:00:00Z","auto_postpone_period_in_days":3,"url":null,"creator":{"id":"U1","name":"Chris","role":"admin","active":true,"email_address":"c@e","created_at":"2026-05-25T00:00:00Z","url":null}}
        ]
        """
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/boards"):
                return (json.data(using: .utf8)!, .ok(for: req))
            default:
                Issue.record("unexpected: \(req.httpMethod ?? "?") \(req.url?.path ?? "?")")
                return (Data(), .response(for: req, status: 500))
            }
        }

        let remoteBoards = try await h.provider.fetchRemoteBoards()

        #expect(remoteBoards.count == 2)
        #expect(remoteBoards[0].id == "FB1")
        #expect(remoteBoards[0].name == "Public Roadmap")
        #expect(remoteBoards[0].provider == "Fizzy")
        #expect(remoteBoards[1].id == "FB2")
        #expect(remoteBoards[1].name == "Private")
        #expect(remoteBoards[0].url == URL(string: "https://fizzy.bluefenix.net/ACCT/boards/FB1"))
        #expect(remoteBoards[1].url == nil)
    }

    @Test("sync() translates FizzySyncResult counts to public SyncResult")
    func syncTranslatesFizzySyncResultToPublicSyncResult() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok"); h.authState.setAccountSlug("ACCT")

        // Pair a local board so sync() actually runs.
        let boardRepo = BoardRepository(context: h.persistence.viewContext)
        let board = boardRepo.createBoard(name: "B")
        _ = boardRepo.createColumn(in: board, name: "C")
        try h.persistence.viewContext.save()
        let mapping = FizzyBoardMapping(defaults: h.mappingDefaults)
        mapping.setPairing(localBoardID: board.id!, fizzyBoardID: "FB1")

        // Seed the remote with one card on one column so the steady-state pull
        // loop creates exactly one local card. itemsCreated must therefore
        // arrive at the public SyncResult as 1 — that proves the field carries
        // through rather than being mapped from the wrong source.
        h.mock.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/my/pins"):
                return (Data("[]".utf8), .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/columns"):
                let body = """
                [{"id":"FC1","name":"C","color":{"name":"Slate","value":"x"},"created_at":"2026-05-25T00:00:00Z"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                let body = """
                [{"id":"fz1","number":1,"title":"R1","status":"published","description":null,"description_html":null,"image_url":null,"has_attachments":false,"tags":[],"golden":false,"last_active_at":"2026-05-25T00:00:00Z","created_at":"2026-05-25T00:00:00Z","url":"https://x/1"}]
                """
                return (body.data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.provider.sync(boardId: board.id!, remoteProjectId: "FB1")

        // Non-trivial values prove the field-by-field translation is correct
        // (swap itemsCreated ↔ itemsDeleted in the provider and this fails).
        #expect(result.itemsCreated == 1)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("lastSyncDate returns mapping.lastSyncAt regardless of boardId")
    func lastSyncDateDelegatesToMapping() {
        let h = Harness(); defer { h.tearDown() }
        // Initially nil — mapping has no recorded sync.
        #expect(h.provider.lastSyncDate(for: UUID()) == nil)
        // After recording on the mapping, the provider exposes it through
        // lastSyncDate(for:) regardless of the boardId argument (singleton
        // pairing — boardId is documented as ignored).
        h.provider.mappingRef.setLastSync(.now)
        #expect(h.provider.lastSyncDate(for: UUID()) != nil)
    }

    @Test("changePairing clears the board mapping but keeps the token (issue #18)")
    func changePairingKeepsToken() {
        let h = Harness(); defer { h.tearDown() }

        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")
        h.provider.mappingRef.setPairing(localBoardID: UUID(), fizzyBoardID: "FB1")
        h.provider.mappingRef.setLastSync(.now)
        #expect(h.provider.mappingRef.isPaired)

        h.provider.changePairing()

        #expect(!h.provider.mappingRef.isPaired)
        #expect(h.provider.mappingRef.localBoardID == nil)
        #expect(h.provider.mappingRef.fizzyBoardID == nil)
        #expect(h.provider.mappingRef.lastSyncAt == nil)
        #expect(h.provider.isAuthenticated, "re-pairing must never cost the token — minting a new one needs email, which may be unavailable")
    }

    @Test("retryPendingSteps uses the store-resolved card number (not the attribute)")
    func retryPendingStepsResolvesStoreFirst() async throws {
        let h = Harness(); defer { h.tearDown() }
        h.authState.setAccessToken("tok")
        h.authState.setAccountSlug("ACCT")

        let ctx = h.persistence.viewContext
        let boardRepo = BoardRepository(context: ctx)
        let board = boardRepo.createBoard(name: "B")
        let column = boardRepo.createColumn(in: board, name: "C")
        let card = CardRepository(context: ctx).createCard(in: column, title: "C")
        // Attribute-unpaired (fizzyNumber 0); store says 5.
        let step = CardStep(context: ctx)
        step.fizzyStepID = "s1"
        step.content = "x"
        step.completed = false
        step.sortOrder = 0
        step.pendingWrite = true
        step.card = card
        try ctx.save()
        h.pairingStore.setPairing(
            FizzyCardPairing(fizzyID: "fzS", fizzyNumber: 5, fizzyUpdatedAt: .now),
            for: card.id!
        )

        h.mock.handler = { request in (Data("{}".utf8), .response(for: request, status: 200)) }
        await h.provider.retryPendingSteps()

        let req = try #require(h.mock.requests.first)
        #expect(req.url?.path.contains("/cards/5/") == true)   // store number, not attribute 0
    }
}
