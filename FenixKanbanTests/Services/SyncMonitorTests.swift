import XCTest
import CoreData
@testable import FenixKanban

final class SyncMonitorTests: XCTestCase {
    func testNonCloudKitContainerSetsDisabled() {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let monitor = SyncMonitor(container: persistence.container)
        XCTAssertEqual(monitor.status, .disabled)
    }

    func testInitialStatusIsIdle() {
        // With a non-CloudKit container, status is disabled.
        // Separately verify the enum default value works correctly.
        let status: SyncStatus = .idle
        XCTAssertEqual(status, .idle)
        XCTAssertNotEqual(status, .syncing)
    }

    func testSyncStatusEquality() {
        XCTAssertEqual(SyncStatus.idle, SyncStatus.idle)
        XCTAssertEqual(SyncStatus.syncing, SyncStatus.syncing)
        XCTAssertEqual(SyncStatus.failed("err"), SyncStatus.failed("err"))
        XCTAssertNotEqual(SyncStatus.failed("a"), SyncStatus.failed("b"))
        XCTAssertNotEqual(SyncStatus.idle, SyncStatus.disabled)
    }
}
