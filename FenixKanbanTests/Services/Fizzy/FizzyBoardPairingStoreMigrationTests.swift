import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardPairingStore migration")
struct FizzyBoardPairingStoreMigrationTests {

    private func makeStore() -> FizzyBoardPairingStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-mig-\(UUID().uuidString).json")
        return FizzyBoardPairingStore(fileURL: url)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fbps-mig-\(UUID().uuidString)")!
    }

    @Test("folds the legacy singleton into row 1 and clears legacy keys")
    func foldsLegacy() {
        let store = makeStore()
        let defaults = makeDefaults()
        let local = UUID()
        defaults.set(local.uuidString, forKey: "fizzy.pairing.localBoardID")
        defaults.set("fz-123", forKey: "fizzy.pairing.fizzyBoardID")
        defaults.set(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 5_000)),
                     forKey: "fizzy.pairing.lastSyncAt")

        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == true)

        let row = store.pairing(forLocal: local)
        #expect(row?.fizzyBoardID == "fz-123")
        #expect(row?.lastSyncAt == Date(timeIntervalSince1970: 5_000))
        #expect(store.all().count == 1)
        // Legacy keys cleared:
        #expect(defaults.string(forKey: "fizzy.pairing.localBoardID") == nil)
        #expect(defaults.string(forKey: "fizzy.pairing.fizzyBoardID") == nil)
    }

    @Test("is idempotent — second call is a no-op")
    func idempotent() {
        let store = makeStore()
        let defaults = makeDefaults()
        defaults.set(UUID().uuidString, forKey: "fizzy.pairing.localBoardID")
        defaults.set("fz-123", forKey: "fizzy.pairing.fizzyBoardID")

        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == true)
        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == false)
        #expect(store.all().count == 1)
    }

    @Test("fresh install with no legacy keys is a no-op")
    func freshNoOp() {
        let store = makeStore()
        let defaults = makeDefaults()
        #expect(store.migrateLegacyMappingIfNeeded(defaults: defaults) == false)
        #expect(store.isEmpty)
    }
}
