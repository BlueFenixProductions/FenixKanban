import Foundation
import os

/// Device-local durable store for detected sync conflicts, keyed by local card UUID.
///
/// One open conflict per card (overwrite on re-conflict). Backed by a JSON sidecar
/// in Application Support, written atomically on every mutation. Loaded once at init;
/// a missing or unreadable file is an empty store.
///
/// NOT a CoreData entity: conflict records are device-local sync facts that must not
/// replicate via CloudKit to other devices — the same reasoning as FizzyCardPairingStore.
final class FizzyConflictStore: @unchecked Sendable {

    /// Process-wide instance backed by the production sidecar file.
    static let shared = FizzyConflictStore()

    let fileURL: URL
    private let lock = NSLock()
    private var records: [String: ConflictRecord]
    private static let logger = Logger(
        subsystem: "com.bluefenixproductions.FenixKanban",
        category: "FizzyConflictStore"
    )

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FenixKanban", directoryHint: .isDirectory)
            .appending(path: "FizzyConflicts.json")
    }

    init(fileURL: URL = FizzyConflictStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ConflictRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    /// Returns the open conflict for the given local card UUID, if any.
    func record(for cardID: UUID) -> ConflictRecord? {
        lock.withLock { records[cardID.uuidString] }
    }

    /// Stores (or overwrites) a conflict record for the given local card UUID.
    func setRecord(_ record: ConflictRecord, for cardID: UUID) {
        lock.withLock {
            records[cardID.uuidString] = record
            persistLocked()
        }
    }

    /// Removes the conflict record for the given local card UUID (after resolution).
    func remove(for cardID: UUID) {
        lock.withLock {
            guard records.removeValue(forKey: cardID.uuidString) != nil else { return }
            persistLocked()
        }
    }

    /// Total number of open conflicts.
    var count: Int {
        lock.withLock { records.count }
    }

    /// Snapshot of all open conflicts.
    var all: [ConflictRecord] {
        lock.withLock { Array(records.values) }
    }

    func removeAll() {
        lock.withLock {
            guard !records.isEmpty else { return }
            records = [:]
            persistLocked()
        }
    }

    /// Must be called with `lock` held. Atomic write.
    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("conflict store persist failed: \(error.localizedDescription)")
        }
    }
}
