import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzySyncProvider multi-board")
@MainActor
struct FizzySyncProviderMultiBoardTests {

    private func makeProvider() -> (FizzySyncProvider, FizzyBoardPairingStore) {
        let store = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "prov-\(UUID()).json")
        )
        let prefix = "test.fizzy.multiboard.\(UUID().uuidString)"
        let authState = FizzyAuthState(keyPrefix: prefix)
        let mappingDefaults = UserDefaults(suiteName: "test.fizzy.multiboard.mapping.\(UUID().uuidString)")!
        let mapping = FizzyBoardMapping(defaults: mappingDefaults)
        let provider = FizzySyncProvider(
            authState: authState,
            mapping: mapping,
            persistence: PersistenceController(inMemory: true, useCloudKit: false),
            boardPairingStore: store
        )
        return (provider, store)
    }

    @Test("isPaired is false with no pairings even when authed-shaped")
    func isPairedRequiresAPairing() {
        let (provider, _) = makeProvider()
        #expect(provider.isPaired == false)
    }

    @Test("pair() and unpair() mutate the store")
    func pairUnpair() {
        let (provider, store) = makeProvider()
        let a = UUID()
        provider.pair(localBoardID: a, fizzyBoardID: "fz-A", fizzyBoardName: "A")
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fz-A")
        provider.unpair(localBoardID: a)
        #expect(store.pairing(forLocal: a) == nil)
    }

    @Test("lastSyncDate(for:) reads that board's row")
    func lastSyncPerBoard() {
        let (provider, store) = makeProvider()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fz-A",
                                       lastSyncAt: Date(timeIntervalSince1970: 10)))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fz-B"))
        #expect(provider.lastSyncDate(for: a) == Date(timeIntervalSince1970: 10))
        #expect(provider.lastSyncDate(for: b) == nil)
    }
}
