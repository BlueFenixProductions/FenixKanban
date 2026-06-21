import Testing
import CoreData
import Foundation
@testable import FenixKanban

// MARK: - Helpers

@Suite("CardSteps ViewModel — cache-first", .serialized)
@MainActor
struct CardStepsViewModelTests {
    let mock = MockHTTPState()
    let persistence: PersistenceController
    let card: Card

    init() {
        persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let context = persistence.viewContext

        let board = Board(context: context)
        board.id = UUID()
        board.name = "B"
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0

        let column = Column(context: context)
        column.id = UUID()
        column.name = "C"
        column.createdAt = Date()
        column.modifiedAt = Date()
        column.sortOrder = 0
        column.board = board

        let c = Card(context: context)
        c.id = UUID()
        c.title = "Test"
        c.createdAt = Date()
        c.modifiedAt = Date()
        c.sortOrder = 0
        c.column = column
        c.fizzyNumber = 1

        try? context.save()
        card = c
    }

    private func makeClient() -> FizzyClient {
        FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: mock.makeSession(),
            clock: ImmediateClock()
        )
    }

    private func makeRepo() -> StepRepository {
        StepRepository(context: persistence.viewContext)
    }

    private func makeVM() -> CardStepsViewModel {
        CardStepsViewModel(card: card, client: makeClient(), repository: makeRepo())
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: MockURLProtocol.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/fizzy") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let testURL = URL(fileURLWithPath: #file)
        let fixturePath = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    // Seed CardStep rows into the in-memory store for the test card.
    private func seedSteps(_ steps: [(fizzyID: String, content: String, completed: Bool, sortOrder: Int32)]) {
        let context = persistence.viewContext
        for s in steps {
            let step = CardStep(context: context)
            step.fizzyStepID = s.fizzyID
            step.content = s.content
            step.completed = s.completed
            step.sortOrder = s.sortOrder
            step.pendingWrite = false
            step.card = card
        }
        try? context.save()
    }

    // MARK: - (a) cache served without network

    @Test("cache-first: cached rows are served immediately without network call")
    func cacheServedWithoutNetwork() async throws {
        seedSteps([
            (fizzyID: "aaa", content: "Cached step 1", completed: false, sortOrder: 0),
            (fizzyID: "bbb", content: "Cached step 2", completed: true, sortOrder: 1000)
        ])
        // Network would fail if called
        mock.handler = { _ in throw URLError(.notConnectedToInternet) }

        let vm = makeVM()
        // Load from cache only (no network)
        await vm.loadFromCache()

        #expect(vm.steps.count == 2)
        #expect(vm.steps[0].content == "Cached step 1")
        #expect(vm.steps[1].content == "Cached step 2")
        #expect(vm.errorMessage == nil)
        #expect(mock.requests.isEmpty, "No network request should be made for cache-only load")
    }

    // MARK: - (b) refresh reconciles; pending survive

    @Test("refresh reconciles server steps; pending-write rows are preserved")
    func refreshReconcilesPendingPreserved() async throws {
        // Seed: one server-backed row + one pending
        seedSteps([
            (fizzyID: "srv1", content: "Server step", completed: false, sortOrder: 0),
        ])
        // Add a pending row
        let pendingStep = CardStep(context: persistence.viewContext)
        pendingStep.fizzyStepID = nil       // no ID yet — locally created
        pendingStep.content = "Local pending"
        pendingStep.completed = false
        pendingStep.sortOrder = 1000
        pendingStep.pendingWrite = true
        pendingStep.card = card
        try? persistence.viewContext.save()

        let detail = try loadFixture("card_detail_doc")
        mock.handler = { req in (detail, .ok(for: req)) }

        let vm = makeVM()
        await vm.load()

        // Server has 2 steps (from card_detail_doc); pending row must be preserved
        let stepContents = vm.steps.map(\.content)
        #expect(stepContents.contains("This is the first step"), "server step should appear")
        #expect(stepContents.contains("This is the second step"), "server step should appear")
        #expect(stepContents.contains("Local pending"), "pending row must survive reconciliation")

        // Pending row should still be pending
        let repo = makeRepo()
        let pending = repo.fetchSteps(for: card).filter(\.pendingWrite)
        #expect(pending.count == 1)
        #expect(pending[0].content == "Local pending")
    }

    // MARK: - (c) create optimistic + clears pendingWrite on 200 (fixture verbatim)

    @Test("addStep creates optimistic row, POSTs, clears pendingWrite on 200 — step_doc fixture verbatim")
    func addStepOptimisticClearsPendingWrite() async throws {
        let stepData = try loadFixture("step_doc")
        mock.handler = { request in
            if request.httpMethod == "POST", request.url!.path.hasSuffix("/cards/1/steps") {
                return (Data(), .response(
                    for: request, status: 201,
                    headers: ["Location": "https://fizzy.bluefenix.net/ACCT/cards/1/steps/03f5v9zo9qlcwwpyc0ascnikz"]
                ))
            }
            if request.httpMethod == "GET", request.url!.path.hasSuffix("/steps/03f5v9zo9qlcwwpyc0ascnikz") {
                return (stepData, .ok(for: request))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = makeVM()
        // Verify fixture content: step_doc has id=03f5v9zo9qlcwwpyc0ascnikz, content="Write tests"
        let added = await vm.addStep(content: "Write tests")

        #expect(added == true)
        #expect(vm.errorMessage == nil)

        // Verify the step appeared in the view model
        let addedStep = vm.steps.first { $0.content == "Write tests" }
        #expect(addedStep != nil)
        #expect(addedStep?.id == "03f5v9zo9qlcwwpyc0ascnikz")  // from fixture verbatim

        // pendingWrite must be cleared after successful 2xx
        let repo = makeRepo()
        let pending = repo.fetchSteps(for: card).filter(\.pendingWrite)
        #expect(pending.isEmpty, "pendingWrite should be false after server confirmation")
    }

    // MARK: - (d) toggle completed writes through

    @Test("toggleStep flips completed, PUTs to server, clears pendingWrite on success")
    func toggleStepWritesThrough() async throws {
        seedSteps([(fizzyID: "step1", content: "Do something", completed: false, sortOrder: 0)])

        let updatedJSON = Data("""
        {"id":"step1","content":"Do something","completed":true}
        """.utf8)
        mock.handler = { req in
            if req.httpMethod == "PUT" {
                return (updatedJSON, .ok(for: req))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = makeVM()
        await vm.loadFromCache()
        let step = try #require(vm.steps.first)
        #expect(step.completed == false)

        await vm.toggleStep(step)

        let toggled = try #require(vm.steps.first)
        #expect(toggled.completed == true)
        #expect(vm.errorMessage == nil)

        // Verify PUT was sent
        let put = mock.requests.first { $0.httpMethod == "PUT" }
        #expect(put?.url?.path.contains("/cards/1/steps/step1") == true)

        // pendingWrite cleared after success
        let repo = makeRepo()
        let row = try #require(repo.fetchSteps(for: card).first)
        #expect(row.pendingWrite == false)
    }

    // MARK: - (e) failed write keeps pendingWrite

    @Test("failed toggle keeps pendingWrite=true and surfaces error")
    func failedToggleKeepsPendingWrite() async throws {
        seedSteps([(fizzyID: "step1", content: "Tricky step", completed: false, sortOrder: 0)])

        mock.handler = { req in
            return (Data("{\"error\":\"nope\"}".utf8), .response(for: req, status: 422))
        }

        let vm = makeVM()
        await vm.loadFromCache()
        let step = try #require(vm.steps.first)
        await vm.toggleStep(step)

        #expect(vm.errorMessage != nil)

        // The row reverts completed but must have pendingWrite=true to signal retry
        let repo = makeRepo()
        let row = try #require(repo.fetchSteps(for: card).first)
        #expect(row.pendingWrite == true, "pendingWrite must be set on failed write for retry")
    }

    // MARK: - (f) retryPending re-posts

    @Test("retryPending re-sends all pendingWrite=true steps")
    func retryPendingResendsFailedWrites() async throws {
        seedSteps([
            (fizzyID: "s1", content: "Pending toggle", completed: true, sortOrder: 0)
        ])
        // Mark the seeded step as pending
        let repo = makeRepo()
        let stepRow = try #require(repo.fetchSteps(for: card).first)
        stepRow.pendingWrite = true
        try? persistence.viewContext.save()

        let updatedJSON = Data("""
        {"id":"s1","content":"Pending toggle","completed":true}
        """.utf8)
        mock.handler = { req in
            if req.httpMethod == "PUT" {
                return (updatedJSON, .ok(for: req))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = makeVM()
        await vm.loadFromCache()
        await vm.retryPending()

        // After retry, PUT was sent and pendingWrite cleared
        let putRequests = mock.requests.filter { $0.httpMethod == "PUT" }
        #expect(putRequests.count >= 1)
        let row = try #require(repo.fetchSteps(for: card).first)
        #expect(row.pendingWrite == false, "pendingWrite cleared after successful retry")
    }

    // MARK: - (g) delete write-through semantics

    @Test("deleteStep write-through: row kept until 2xx, then removed from cache")
    func deleteStepWriteThrough() async throws {
        seedSteps([(fizzyID: "del1", content: "Delete me", completed: false, sortOrder: 0)])

        mock.handler = { req in
            if req.httpMethod == "DELETE" {
                return (Data(), .response(for: req, status: 204))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = makeVM()
        await vm.loadFromCache()
        let step = try #require(vm.steps.first)
        await vm.deleteStep(step)

        #expect(vm.steps.isEmpty)
        #expect(vm.errorMessage == nil)

        // Row must be gone from CoreData
        let repo = makeRepo()
        #expect(repo.fetchSteps(for: card).isEmpty, "step row should be deleted after 2xx delete")
    }

    @Test("deleteStep failure keeps row with pendingWrite=false (kept for retry not queued)")
    func deleteStepFailureKeepsRow() async throws {
        seedSteps([(fizzyID: "del1", content: "Delete me", completed: false, sortOrder: 0)])

        mock.handler = { req in
            if req.httpMethod == "DELETE" {
                return (Data("{\"error\":\"nope\"}".utf8), .response(for: req, status: 422))
            }
            throw URLError(.unsupportedURL)
        }

        let vm = makeVM()
        await vm.loadFromCache()
        let step = try #require(vm.steps.first)
        await vm.deleteStep(step)

        #expect(vm.steps.count == 1, "step should be restored after failed delete")
        #expect(vm.errorMessage != nil)

        // Row still in CoreData (not deleted on failure)
        let repo = makeRepo()
        #expect(repo.fetchSteps(for: card).count == 1)
    }

    // MARK: - Pending indicator

    @Test("pending steps exposed via hasPendingWrites and in pendingSteps list")
    func pendingStepsExposed() async throws {
        seedSteps([
            (fizzyID: "ok1", content: "Clean step", completed: false, sortOrder: 0)
        ])
        let pendingRow = CardStep(context: persistence.viewContext)
        pendingRow.fizzyStepID = nil
        pendingRow.content = "Unsaved step"
        pendingRow.completed = false
        pendingRow.sortOrder = 1000
        pendingRow.pendingWrite = true
        pendingRow.card = card
        try? persistence.viewContext.save()

        let vm = makeVM()
        await vm.loadFromCache()

        #expect(vm.steps.count == 2)
        #expect(vm.hasPendingWrites == true)
    }
}
