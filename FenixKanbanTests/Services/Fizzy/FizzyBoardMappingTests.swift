import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardMapping", .serialized)
struct FizzyBoardMappingTests {

    private let suiteName: String
    private let defaults: UserDefaults
    private let mapping: FizzyBoardMapping

    init() {
        suiteName = "test.fizzy.mapping.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        mapping = FizzyBoardMapping(defaults: defaults)
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("default state: unpaired, nil ids, nil lastSyncAt")
    func defaultState() {
        defer { tearDown() }
        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)
        #expect(mapping.isPaired == false)
    }

    @Test("setPairing stores both IDs and isPaired flips true")
    func setPairing() {
        defer { tearDown() }
        let localID = UUID()
        mapping.setPairing(localBoardID: localID, fizzyBoardID: "fizzy-123")

        #expect(mapping.localBoardID == localID)
        #expect(mapping.fizzyBoardID == "fizzy-123")
        #expect(mapping.isPaired == true)
    }

    @Test("setLastSync round-trips an ISO8601 date")
    func lastSyncRoundTrip() throws {
        defer { tearDown() }
        let now = Date(timeIntervalSince1970: 1_734_567_890)
        mapping.setLastSync(now)

        let read = try #require(mapping.lastSyncAt)
        #expect(abs(read.timeIntervalSince(now)) < 1)
    }

    @Test("clear() removes all three keys; isPaired returns to false")
    func clearResets() {
        defer { tearDown() }
        mapping.setPairing(localBoardID: UUID(), fizzyBoardID: "x")
        mapping.setLastSync(Date())
        #expect(mapping.isPaired == true)

        mapping.clear()

        #expect(mapping.localBoardID == nil)
        #expect(mapping.fizzyBoardID == nil)
        #expect(mapping.lastSyncAt == nil)
        #expect(mapping.isPaired == false)
    }
}
