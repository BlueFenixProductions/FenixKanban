import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyBoardPairingStore")
struct FizzyBoardPairingStoreTests {

    /// Hermetic store backed by a unique temp file (never the real sidecar).
    private func makeStore() -> FizzyBoardPairingStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-\(UUID().uuidString).json")
        return FizzyBoardPairingStore(fileURL: url)
    }

    @Test("upsert inserts then updates in place, preserving order")
    func upsertInsertsThenUpdates() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fb"))
        #expect(store.all().map(\.localBoardID) == [a, b])

        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa2"))
        #expect(store.all().map(\.localBoardID) == [a, b])           // order kept
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fa2")    // value replaced
    }

    @Test("lookups by local and fizzy id")
    func lookups() {
        let store = makeStore()
        let a = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        #expect(store.pairing(forLocal: a)?.fizzyBoardID == "fa")
        #expect(store.pairing(forFizzy: "fa")?.localBoardID == a)
        #expect(store.pairing(forLocal: UUID()) == nil)
    }

    @Test("setLastSync and setSyncEnabled mutate the row")
    func mutators() {
        let store = makeStore()
        let a = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        let when = Date(timeIntervalSince1970: 1_000)
        store.setLastSync(localBoardID: a, when)
        store.setSyncEnabled(localBoardID: a, false)
        #expect(store.pairing(forLocal: a)?.lastSyncAt == when)
        #expect(store.pairing(forLocal: a)?.syncEnabled == false)
    }

    @Test("remove and clearAll")
    func removal() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa"))
        store.upsert(FizzyBoardPairing(localBoardID: b, fizzyBoardID: "fb"))
        store.remove(localBoardID: a)
        #expect(store.all().map(\.localBoardID) == [b])
        store.clearAll()
        #expect(store.isEmpty)
    }

    @Test("persists across instances on the same file")
    func persistence() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fbps-\(UUID().uuidString).json")
        let a = UUID()
        do {
            let store = FizzyBoardPairingStore(fileURL: url)
            store.upsert(FizzyBoardPairing(localBoardID: a, fizzyBoardID: "fa", fizzyBoardName: "Sandbox"))
        }
        let reopened = FizzyBoardPairingStore(fileURL: url)
        #expect(reopened.pairing(forLocal: a)?.fizzyBoardName == "Sandbox")
    }

    @Test("missing file is an empty store")
    func missingFileEmpty() {
        let store = FizzyBoardPairingStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID()).json")
        )
        #expect(store.isEmpty)
    }
}
