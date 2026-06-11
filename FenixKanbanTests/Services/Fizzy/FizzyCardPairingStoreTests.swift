import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzyCardPairingStore (issue #21 A′)")
struct FizzyCardPairingStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fk-pairing-tests-\(UUID().uuidString)")
            .appendingPathComponent("FizzyCardPairings.json")
    }

    @Test("set/get/remove round-trip in memory")
    func roundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FizzyCardPairingStore(fileURL: url)
        let id = UUID()
        #expect(store.isEmpty)
        #expect(store.pairing(for: id) == nil)

        let pairing = FizzyCardPairing(fizzyID: "fz1", fizzyNumber: 7, fizzyUpdatedAt: Date(timeIntervalSince1970: 1_000_000))
        store.setPairing(pairing, for: id)
        #expect(store.pairing(for: id) == pairing)
        #expect(store.count == 1)
        #expect(!store.isEmpty)

        store.removePairing(for: id)
        #expect(store.pairing(for: id) == nil)
        #expect(store.isEmpty)
    }

    @Test("pairings persist across instances sharing a file URL")
    func persistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        // Sub-second component on purpose: LWW comparisons need exact Date
        // fidelity through the JSON round-trip.
        let stamp = Date(timeIntervalSinceReferenceDate: 768_000_000.123456)
        FizzyCardPairingStore(fileURL: url)
            .setPairing(FizzyCardPairing(fizzyID: "fzA", fizzyNumber: 21, fizzyUpdatedAt: stamp), for: id)

        let reloaded = FizzyCardPairingStore(fileURL: url)
        let pairing = reloaded.pairing(for: id)
        #expect(pairing?.fizzyID == "fzA")
        #expect(pairing?.fizzyNumber == 21)
        #expect(pairing?.fizzyUpdatedAt == stamp)
    }

    @Test("missing or corrupt file loads as an empty store")
    func corruptFileLoadsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json{{".utf8).write(to: url)
        let store = FizzyCardPairingStore(fileURL: url)
        #expect(store.isEmpty)
        // And it recovers: the next write succeeds.
        let id = UUID()
        store.setPairing(FizzyCardPairing(fizzyID: "fzB", fizzyNumber: 1, fizzyUpdatedAt: .now), for: id)
        #expect(FizzyCardPairingStore(fileURL: url).pairing(for: id)?.fizzyID == "fzB")
    }

    @Test("allPairings snapshots every entry; removeAll wipes the file")
    func allPairingsAndRemoveAll() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FizzyCardPairingStore(fileURL: url)
        let a = UUID(), b = UUID()
        store.setPairing(FizzyCardPairing(fizzyID: "fzA", fizzyNumber: 1, fizzyUpdatedAt: .now), for: a)
        store.setPairing(FizzyCardPairing(fizzyID: "fzB", fizzyNumber: 2, fizzyUpdatedAt: .now), for: b)
        let all = store.allPairings()
        #expect(Set(all.keys) == [a, b])

        store.removeAll()
        #expect(store.isEmpty)
        #expect(FizzyCardPairingStore(fileURL: url).isEmpty, "removeAll persists")
    }
}
