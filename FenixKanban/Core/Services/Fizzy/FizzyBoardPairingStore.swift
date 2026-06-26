import Foundation
import os

/// One local board's pairing with its Fizzy twin (Phase 7, issue #18).
struct FizzyBoardPairing: Codable, Equatable {
    var localBoardID: UUID
    var fizzyBoardID: String
    var fizzyBoardName: String?
    var lastSyncAt: Date?
    var etag: String?
    var syncEnabled: Bool

    init(
        localBoardID: UUID,
        fizzyBoardID: String,
        fizzyBoardName: String? = nil,
        lastSyncAt: Date? = nil,
        etag: String? = nil,
        syncEnabled: Bool = true
    ) {
        self.localBoardID = localBoardID
        self.fizzyBoardID = fizzyBoardID
        self.fizzyBoardName = fizzyBoardName
        self.lastSyncAt = lastSyncAt
        self.etag = etag
        self.syncEnabled = syncEnabled
    }
}

/// Device-local, insertion-ordered store of board pairings (issue #18).
///
/// Like `FizzyCardPairingStore`, pairing is device-truth, not document-truth:
/// it must live where CloudKit's multi-device merges cannot duplicate it
/// (issues #21/#22). Backed by a JSON sidecar written atomically on every
/// mutation; a missing or unreadable file is an empty store.
final class FizzyBoardPairingStore: @unchecked Sendable {

    static let shared = FizzyBoardPairingStore()

    let fileURL: URL
    private let lock = NSLock()
    private var pairings: [FizzyBoardPairing]   // insertion-ordered
    private static let logger = Logger(
        subsystem: "com.bluefenixproductions.FenixKanban",
        category: "FizzyBoardPairingStore"
    )

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FenixKanban", directoryHint: .isDirectory)
            .appending(path: "FizzyBoardPairings.json")
    }

    init(fileURL: URL = FizzyBoardPairingStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([FizzyBoardPairing].self, from: data) {
            pairings = decoded
        } else {
            pairings = []
        }
    }

    var isEmpty: Bool { lock.withLock { pairings.isEmpty } }
    var count: Int { lock.withLock { pairings.count } }

    func all() -> [FizzyBoardPairing] { lock.withLock { pairings } }

    func pairing(forLocal id: UUID) -> FizzyBoardPairing? {
        lock.withLock { pairings.first { $0.localBoardID == id } }
    }

    func pairing(forFizzy id: String) -> FizzyBoardPairing? {
        lock.withLock { pairings.first { $0.fizzyBoardID == id } }
    }

    func upsert(_ pairing: FizzyBoardPairing) {
        lock.withLock {
            if let i = pairings.firstIndex(where: { $0.localBoardID == pairing.localBoardID }) {
                pairings[i] = pairing
            } else {
                pairings.append(pairing)
            }
            persistLocked()
        }
    }

    func setLastSync(localBoardID id: UUID, _ date: Date) {
        lock.withLock {
            guard let i = pairings.firstIndex(where: { $0.localBoardID == id }) else { return }
            pairings[i].lastSyncAt = date
            persistLocked()
        }
    }

    func setSyncEnabled(localBoardID id: UUID, _ enabled: Bool) {
        lock.withLock {
            guard let i = pairings.firstIndex(where: { $0.localBoardID == id }) else { return }
            pairings[i].syncEnabled = enabled
            persistLocked()
        }
    }

    func remove(localBoardID id: UUID) {
        lock.withLock {
            let before = pairings.count
            pairings.removeAll { $0.localBoardID == id }
            if pairings.count != before { persistLocked() }
        }
    }

    func clearAll() {
        lock.withLock {
            guard !pairings.isEmpty else { return }
            pairings = []
            persistLocked()
        }
    }

    /// One-time, idempotent fold of the legacy `FizzyBoardMapping` singleton
    /// (three `UserDefaults` keys) into row 1. Writes the new row BEFORE
    /// deleting the legacy keys, so a crash mid-migration never loses the
    /// pairing. Returns `true` only when a legacy pairing was folded in.
    @discardableResult
    func migrateLegacyMappingIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let migratedKey = "fizzy.pairing.migratedToBoardStore.v1"
        guard !defaults.bool(forKey: migratedKey) else { return false }

        let localKey = "fizzy.pairing.localBoardID"
        let fizzyKey = "fizzy.pairing.fizzyBoardID"
        let lastSyncKey = "fizzy.pairing.lastSyncAt"

        guard let localStr = defaults.string(forKey: localKey),
              let localID = UUID(uuidString: localStr),
              let fizzyID = defaults.string(forKey: fizzyKey) else {
            defaults.set(true, forKey: migratedKey)   // nothing to migrate; don't recheck
            return false
        }

        let lastSync = defaults.string(forKey: lastSyncKey)
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        upsert(FizzyBoardPairing(
            localBoardID: localID,
            fizzyBoardID: fizzyID,
            lastSyncAt: lastSync
        ))   // new row persisted to sidecar first

        defaults.removeObject(forKey: localKey)
        defaults.removeObject(forKey: fizzyKey)
        defaults.removeObject(forKey: lastSyncKey)
        defaults.set(true, forKey: migratedKey)
        return true
    }

    /// Must be called with `lock` held. Atomic write. Default Codable Date
    /// representation keeps exact fidelity (do NOT switch to .iso8601).
    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(pairings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("board pairing store persist failed: \(error.localizedDescription)")
        }
    }
}
