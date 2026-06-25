import Foundation
import os

/// One local card's pairing with its Fizzy twin.
struct FizzyCardPairing: Codable, Equatable {
    var fizzyID: String
    var fizzyNumber: Int64
    var fizzyUpdatedAt: Date
}

/// Device-local card-pairing store, keyed by local card UUID (issue #21 A′).
///
/// Pairing is device-truth, not document-truth: which remote card a local
/// card maps to is a fact about THIS device's sync session. It must live
/// where neither CloudKit (whose imports clobber freshly written attribute
/// values with stale record versions — issue #21) nor the Fizzy server
/// (whose ActionText sanitizer strips embedded adoption markers on write)
/// can touch it.
///
/// Backed by a JSON sidecar in Application Support, written atomically on
/// every mutation. Loaded once at init; a missing or unreadable file is an
/// empty store — `FizzySyncEngine.seedPairingStoreFromHints` re-seeds from the
/// CloudKit hint attributes and the orphan-claim heuristic heals the rest.
final class FizzyCardPairingStore: @unchecked Sendable {

    /// Process-wide instance backed by the production sidecar file.
    static let shared = FizzyCardPairingStore()

    let fileURL: URL
    private let lock = NSLock()
    private var pairings: [String: FizzyCardPairing]
    private static let logger = Logger(subsystem: "com.bluefenixproductions.FenixKanban", category: "FizzyCardPairingStore")

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FenixKanban", directoryHint: .isDirectory)
            .appending(path: "FizzyCardPairings.json")
    }

    init(fileURL: URL = FizzyCardPairingStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: FizzyCardPairing].self, from: data) {
            pairings = decoded
        } else {
            pairings = [:]
        }
    }

    var isEmpty: Bool { lock.withLock { pairings.isEmpty } }
    var count: Int { lock.withLock { pairings.count } }

    func pairing(for cardID: UUID) -> FizzyCardPairing? {
        lock.withLock { pairings[cardID.uuidString] }
    }

    func setPairing(_ pairing: FizzyCardPairing, for cardID: UUID) {
        lock.withLock {
            pairings[cardID.uuidString] = pairing
            persistLocked()
        }
    }

    func removePairing(for cardID: UUID) {
        lock.withLock {
            guard pairings.removeValue(forKey: cardID.uuidString) != nil else { return }
            persistLocked()
        }
    }

    func removeAll() {
        lock.withLock {
            guard !pairings.isEmpty else { return }
            pairings = [:]
            persistLocked()
        }
    }

    /// Snapshot of every pairing, keyed by card UUID.
    func allPairings() -> [UUID: FizzyCardPairing] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: pairings.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
    }

    /// Must be called with `lock` held. Atomic write. The default Codable
    /// Date representation (timeIntervalSinceReferenceDate as Double) keeps
    /// exact Date fidelity through the round-trip — LWW comparisons depend
    /// on it; do NOT switch to .iso8601 (truncates sub-second precision).
    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(pairings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Degrades to in-memory pairing for this launch; the next
            // sync's cold-store seeding + orphan heuristic recover.
            Self.logger.error("pairing store persist failed: \(error.localizedDescription)")
        }
    }
}
