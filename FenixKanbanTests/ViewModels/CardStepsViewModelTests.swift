import Testing
import Foundation
@testable import FenixKanban

@Suite("CardSteps ViewModel", .serialized)
@MainActor
struct CardStepsViewModelTests {

    private func makeClient() -> FizzyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FizzyClient(
            baseURL: URL(string: "https://fizzy.bluefenix.net")!,
            accessToken: "t",
            accountSlug: "ACCT",
            urlSession: URLSession(configuration: config),
            clock: ImmediateClock()
        )
    }

    // Same fixture-resolution strategy as FizzyClientTests.loadFixture.
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
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("fizzy")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            Issue.record("Could not locate fixture \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fixturePath)
    }

    @Test("load fetches the card detail and exposes its steps (fixture verbatim)")
    func loadExposesSteps() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        MockURLProtocol.handler = { request in
            (detail, .ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()

        #expect(vm.steps.count == 2)
        let first = try #require(vm.steps.first)
        #expect(first.content == "This is the first step")
        #expect(first.completed == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.progressText == "Steps (0/2)")
    }

    @Test("addStep POSTs, follows Location, appends the created step")
    func addStepAppends() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let stepData = try loadFixture("step_doc")
        MockURLProtocol.handler = { request in
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

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.addStep(content: "Write tests")

        #expect(vm.steps.map(\.content) == ["Write tests"])
        #expect(vm.errorMessage == nil)
    }

    @Test("addStep ignores whitespace-only content without a network call")
    func addStepIgnoresEmpty() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { _ in throw URLError(.unsupportedURL) }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.addStep(content: "   ")

        #expect(vm.steps.isEmpty)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("toggleStep flips optimistically and PUTs the new completed state")
    func toggleStepPuts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        let updated = Data("""
        {"id":"03f8huu0sog76g3s975963b5e","content":"This is the first step","completed":true}
        """.utf8)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                return (updated, .ok(for: request))
            }
            return (detail, .ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()
        let first = try #require(vm.steps.first)
        await vm.toggleStep(first)

        let toggled = try #require(vm.steps.first)
        #expect(toggled.completed == true)
        #expect(vm.progressText == "Steps (1/2)")
        let put = MockURLProtocol.requests.first { $0.httpMethod == "PUT" }
        #expect(put?.url?.path.hasSuffix("/cards/1/steps/03f8huu0sog76g3s975963b5e") == true)
    }

    @Test("toggleStep reverts on 422 and surfaces an error")
    func toggleStepReverts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                return (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
            }
            return (detail, .ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()
        let first = try #require(vm.steps.first)
        await vm.toggleStep(first)

        let reverted = try #require(vm.steps.first)
        #expect(reverted.completed == false)
        #expect(vm.errorMessage != nil)
    }

    @Test("deleteStep removes optimistically; 422 restores at original index")
    func deleteStepReverts() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        // Phase 1: DELETE fails with 422.
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Data("{\"error\":\"nope\"}".utf8), .response(for: request, status: 422))
            }
            return (detail, .ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()

        // Failed delete restores the step at index 0.
        let first = try #require(vm.steps.first)
        await vm.deleteStep(first)
        #expect(vm.steps.count == 2)
        let restored = try #require(vm.steps.first)
        #expect(restored.content == "This is the first step")
        #expect(vm.errorMessage != nil)

        // Phase 2: reassign the handler so DELETE now succeeds with 204.
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Data(), .response(for: request, status: 204))
            }
            return (detail, .ok(for: request))
        }
        vm.errorMessage = nil
        await vm.deleteStep(try #require(vm.steps.first))
        #expect(vm.steps.map(\.content) == ["This is the second step"])
        #expect(vm.errorMessage == nil)
    }

    @Test("deleteSteps(at:) snapshots steps before awaiting — both rows go")
    func deleteStepsSnapshotsBeforeAwait() async throws {
        // IndexSet([0, 1]) over the 2-step fixture: deleting row 0 shifts
        // row 1 to index 0, so a naive index walk would skip (or crash on)
        // the second row. deleteSteps must snapshot step VALUES via
        // compactMap BEFORE its first await — both steps end up removed.
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let detail = try loadFixture("card_detail_doc")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Data(), .response(for: request, status: 204))
            }
            return (detail, .ok(for: request))
        }

        let vm = CardStepsViewModel(cardNumber: 1, client: makeClient())
        await vm.load()
        #expect(vm.steps.count == 2)

        await vm.deleteSteps(at: IndexSet([0, 1]))

        #expect(vm.steps.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(MockURLProtocol.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
    }
}
