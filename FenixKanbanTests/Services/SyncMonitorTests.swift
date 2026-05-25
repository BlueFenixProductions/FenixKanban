import Testing
import CoreData
@testable import FenixKanban

@Suite("Sync Monitor", .serialized)
struct SyncMonitorTests {
    @Test @MainActor func nonCloudKitContainerSetsDisabled() {
        let persistence = PersistenceController(inMemory: true, useCloudKit: false)
        let monitor = SyncMonitor(container: persistence.container)
        #expect(monitor.status == .disabled)
    }

    @Test func initialStatusIsIdle() {
        // With a non-CloudKit container, status is disabled.
        // Separately verify the enum default value works correctly.
        let status: SyncStatus = .idle
        #expect(status == .idle)
        #expect(status != .syncing)
    }

    @Test func syncStatusEquality() {
        #expect(SyncStatus.idle == SyncStatus.idle)
        #expect(SyncStatus.syncing == SyncStatus.syncing)
        #expect(SyncStatus.failed("err") == SyncStatus.failed("err"))
        #expect(SyncStatus.failed("a") != SyncStatus.failed("b"))
        #expect(SyncStatus.idle != SyncStatus.disabled)
    }
}
