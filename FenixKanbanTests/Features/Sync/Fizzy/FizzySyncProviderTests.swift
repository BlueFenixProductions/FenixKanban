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
        let persistence: PersistenceController
        let authState: FizzyAuthState
        let mappingDefaults: UserDefaults
        let suiteName: String
        let provider: FizzySyncProvider

        @MainActor
        init() {
            MockURLProtocol.reset()
            persistence = PersistenceController(inMemory: true, useCloudKit: false)

            let prefix = "test.fizzy.provider.\(UUID().uuidString)"
            authState = FizzyAuthState(keyPrefix: prefix)

            suiteName = "test.fizzy.provider.mapping.\(UUID().uuidString)"
            mappingDefaults = UserDefaults(suiteName: suiteName)!
            let mapping = FizzyBoardMapping(defaults: mappingDefaults)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: config)

            provider = FizzySyncProvider(
                authState: authState,
                mapping: mapping,
                persistence: persistence,
                urlSession: session,
                clock: ImmediateClock()
            )
        }

        func tearDown() {
            authState.clear()
            mappingDefaults.removePersistentDomain(forName: suiteName)
            MockURLProtocol.reset()
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
        MockURLProtocol.handler = { req in
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

        // Steady-state sync fetches empty columns/cards — engine returns zero changes.
        MockURLProtocol.handler = { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", let p?) where p.hasSuffix("/columns"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            case ("GET", let p?) where p.hasSuffix("/cards"):
                return ("[]".data(using: .utf8)!, .ok(for: req))
            default:
                return (Data(), .response(for: req, status: 500))
            }
        }

        let result = try await h.provider.sync(boardId: board.id!, remoteProjectId: "FB1")

        #expect(result.itemsCreated == 0)
        #expect(result.itemsUpdated == 0)
        #expect(result.itemsDeleted == 0)
        #expect(result.errors.isEmpty)
    }
}
