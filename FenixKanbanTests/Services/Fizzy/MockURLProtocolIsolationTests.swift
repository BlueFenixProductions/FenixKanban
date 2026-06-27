import Testing
import Foundation
@testable import FenixKanban

/// Issue #10: the mock's state must be per-session, not static — two suites
/// running in parallel must never see each other's handlers or request logs.
/// Deliberately NOT `.serialized`: in-test concurrency is the point.
@Suite("MockURLProtocol per-session isolation (issue #10)")
struct MockURLProtocolIsolationTests {
    @Test("two concurrent sessions keep separate handlers and request logs")
    func twoSessionsStayIsolated() async throws {
        let mockA = MockHTTPState()
        let mockB = MockHTTPState()
        mockA.handler = { req in (Data("A".utf8), .ok(for: req)) }
        mockB.handler = { req in (Data("B".utf8), .ok(for: req)) }
        let sessionA = mockA.makeSession()
        let sessionB = mockB.makeSession()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let (data, _) = try await sessionA.data(from: URL(string: "https://a.test/\(i)")!)
                    #expect(String(decoding: data, as: UTF8.self) == "A")
                }
                group.addTask {
                    let (data, _) = try await sessionB.data(from: URL(string: "https://b.test/\(i)")!)
                    #expect(String(decoding: data, as: UTF8.self) == "B")
                }
            }
            try await group.waitForAll()
        }

        #expect(mockA.requests.count == 20)
        #expect(mockB.requests.count == 20)
        #expect(mockA.requests.allSatisfy { $0.url?.host == "a.test" })
        #expect(mockB.requests.allSatisfy { $0.url?.host == "b.test" })
    }
}
