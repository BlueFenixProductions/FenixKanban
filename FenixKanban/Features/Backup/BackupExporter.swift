import Foundation
import CoreData

/// Writes a verified backup of a CoreData store to a `.fenixkanban-backup`
/// directory bundle, then immediately re-opens that bundle into a throwaway
/// `NSPersistentContainer` and confirms every entity's row count matches the
/// manifest captured at export time.
///
/// Phase 4c ships the export side only. Restore is a documented manual
/// process (close app, replace store files in
/// `~/Library/Application Support/...`/iOS app container, relaunch).
@MainActor
final class BackupExporter {

    enum ExportError: Error, Equatable, CustomStringConvertible {
        case sourceStoreMissing
        case fileSystem(String)
        case verificationFailed(String)
        case manifestMissing
        case manifestCorrupt(String)

        var description: String {
            switch self {
            case .sourceStoreMissing:
                return "Source CoreData store URL is nil — was the container loaded?"
            case .fileSystem(let m): return "File system: \(m)"
            case .verificationFailed(let m): return "Verification failed: \(m)"
            case .manifestMissing: return "Backup is missing manifest.json"
            case .manifestCorrupt(let m): return "Backup manifest corrupt: \(m)"
            }
        }
    }

    struct Summary: Equatable {
        let path: URL
        let counts: [String: Int]
        let bytesWritten: Int64
        let verifiedAt: Date
    }

    private static let manifestFilename = "manifest.json"
    private static let storeFilename = "store.sqlite"
    private static let walFilename = "store.sqlite-wal"
    private static let shmFilename = "store.sqlite-shm"
    private static let schemaName = "FenixKanban 3"

    /// Exports the container's persistent store to `destination` (a
    /// `.fenixkanban-backup` directory bundle), then verifies the export
    /// before returning. Throws `ExportError` on any failure; the destination
    /// directory is left in place even on verification failure so the engineer
    /// can inspect what went wrong.
    func exportVerified(to destination: URL, from container: NSPersistentContainer) async throws -> Summary {
        let liveCounts = try entityCounts(in: container)
        let sourceURL = try sourceStoreURL(from: container)

        // 1. Create destination directory (clean slate if it already exists).
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 2. Copy the three SQLite files (sidecars may not exist — that's fine).
        // SQLite WAL/SHM live next to the main store with a SUFFIX on the
        // last path component: store.sqlite → store.sqlite-wal, store.sqlite-shm.
        // (NOT a second path extension — that would be store.sqlite.wal.)
        try copyIfExists(at: sourceURL,
                         to: destination.appendingPathComponent(Self.storeFilename))
        try copyIfExists(at: sidecarURL(for: sourceURL, suffix: "-wal"),
                         to: destination.appendingPathComponent(Self.walFilename))
        try copyIfExists(at: sidecarURL(for: sourceURL, suffix: "-shm"),
                         to: destination.appendingPathComponent(Self.shmFilename))

        // 3. Write manifest.
        let manifest = BackupManifest(
            version: 1,
            exportedAt: .now,
            schemaName: Self.schemaName,
            entityCounts: liveCounts
        )
        let manifestURL = destination.appendingPathComponent(Self.manifestFilename)
        try manifest.encoded().write(to: manifestURL, options: .atomic)

        // 4. Compute bytesWritten.
        let bytes = try directoryBytes(at: destination)

        // 5. Verify by loading the bundle into a temp container.
        try await verify(bundleAt: destination)

        return Summary(path: destination, counts: liveCounts, bytesWritten: bytes, verifiedAt: .now)
    }

    /// Opens the bundle into a throwaway `NSPersistentContainer`, recounts
    /// every entity, and compares to the manifest. Throws on any mismatch.
    func verify(bundleAt bundleURL: URL) async throws {
        let manifest = try Self.readManifest(at: bundleURL)

        // Copy the SQLite files into a fresh temp dir so the verify container
        // doesn't share files with the live one.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupVerify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let verifyStoreURL = scratch.appendingPathComponent(Self.storeFilename)
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.storeFilename), to: verifyStoreURL)
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.walFilename),
                         to: scratch.appendingPathComponent(Self.walFilename))
        try copyIfExists(at: bundleURL.appendingPathComponent(Self.shmFilename),
                         to: scratch.appendingPathComponent(Self.shmFilename))

        let container = NSPersistentContainer(name: "FenixKanban", managedObjectModel: PersistenceController.sharedModel)
        let desc = NSPersistentStoreDescription(url: verifyStoreURL)
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, err in loadError = err }
        if let loadError {
            throw ExportError.verificationFailed("can't load exported store: \(loadError)")
        }

        let derived = try entityCounts(in: container)

        // Explicitly remove the store so SQLite checkpoints the WAL and
        // releases its file descriptors before the deferred scratch-dir
        // removal runs. Without this, the temp dir gets deleted out from
        // under SQLite and `BUG IN CLIENT OF libsqlite3.dylib` is logged.
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try? container.persistentStoreCoordinator.remove(store)
        }

        guard derived == manifest.entityCounts else {
            throw ExportError.verificationFailed(
                "manifest \(manifest.entityCounts) ≠ derived \(derived)"
            )
        }
    }

    /// Public so callers can read a manifest without doing a full verify
    /// (used by tests and future restore UI).
    static func readManifest(at bundleURL: URL) throws -> BackupManifest {
        let manifestURL = bundleURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExportError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExportError.manifestCorrupt("read: \(error)")
        }
        do {
            return try BackupManifest.decoded(from: data)
        } catch {
            throw ExportError.manifestCorrupt("decode: \(error)")
        }
    }

    // MARK: - Helpers

    private func entityCounts(in container: NSPersistentContainer) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let ctx = container.viewContext
        for entity in PersistenceController.sharedModel.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSNumber>(entityName: name)
            request.resultType = .countResultType
            let count = try ctx.count(for: request)
            out[name] = count
        }
        return out
    }

    private func sourceStoreURL(from container: NSPersistentContainer) throws -> URL {
        guard let url = container.persistentStoreCoordinator.persistentStores.first?.url else {
            throw ExportError.sourceStoreMissing
        }
        return url
    }

    private func copyIfExists(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw ExportError.fileSystem("copy \(source.lastPathComponent): \(error)")
        }
    }

    private func directoryBytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Builds the URL of a SQLite sidecar file by appending `suffix` to the
    /// last path component of `sourceURL`. Used for `-wal` and `-shm`.
    /// Example: `…/store.sqlite` + `-wal` → `…/store.sqlite-wal`.
    private func sidecarURL(for sourceURL: URL, suffix: String) -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.lastPathComponent + suffix
        return parent.appendingPathComponent(filename)
    }
}
