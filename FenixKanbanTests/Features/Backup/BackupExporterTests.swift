import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("BackupExporter")
@MainActor
struct BackupExporterTests {

    /// Removes all persistent stores from `container` so SQLite can checkpoint
    /// its WAL and release file descriptors before the temp directory is
    /// deleted. Without this, `defer { try? FileManager.default.removeItem }`
    /// deletes files out from under open SQLite handles and triggers
    /// `BUG IN CLIENT OF libsqlite3.dylib` log noise.
    private func drainContainer(_ container: NSPersistentContainer) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    /// Builds an isolated on-disk store in a temp dir. We need on-disk because
    /// the exporter copies the SQLite files; an in-memory store has nothing
    /// to copy.
    private func makeOnDiskContainer(seedBoards: Int = 1, cardsPerBoard: Int = 3) throws -> (NSPersistentContainer, URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackupExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("store.sqlite")

        let container = NSPersistentContainer(name: "FenixKanban", managedObjectModel: PersistenceController.sharedModel)
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, err in loadError = err }
        if let loadError { throw loadError }

        let ctx = container.viewContext
        let boardRepo = BoardRepository(context: ctx)
        let cardRepo = CardRepository(context: ctx)
        for i in 0..<seedBoards {
            let b = boardRepo.createBoard(name: "Board \(i)")
            let col = boardRepo.createColumn(in: b, name: "Todo")
            for j in 0..<cardsPerBoard {
                _ = cardRepo.createCard(in: col, title: "Card \(i)-\(j)")
            }
        }
        try ctx.save()
        return (container, tempDir)
    }

    @Test("export verified round-trip — counts match")
    func roundTrip() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 2, cardsPerBoard: 4)
        defer { drainContainer(container); try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        let summary = try await exporter.exportVerified(to: destination, from: container)

        #expect(summary.counts["Board"] == 2)
        #expect(summary.counts["Column"] == 2)
        #expect(summary.counts["Card"] == 8)
        #expect(summary.bytesWritten > 0)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("store.sqlite").path))
    }

    @Test("empty store round-trip")
    func emptyStoreRoundTrip() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 0, cardsPerBoard: 0)
        defer { drainContainer(container); try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        let summary = try await exporter.exportVerified(to: destination, from: container)

        #expect(summary.counts["Board"] == 0)
        #expect(summary.counts["Card"] == 0)
    }

    @Test("verifier rejects corrupted store (truncated SQLite)")
    func rejectsCorruption() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 1, cardsPerBoard: 5)
        defer { drainContainer(container); try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()

        // First, successfully export.
        _ = try await exporter.exportVerified(to: destination, from: container)

        // Now corrupt the exported SQLite file then re-run just the verifier path.
        let storePath = destination.appendingPathComponent("store.sqlite")
        try Data(repeating: 0, count: 32).write(to: storePath)  // overwrite with junk

        await #expect(throws: BackupExporter.ExportError.self) {
            _ = try await exporter.verify(bundleAt: destination)
        }
    }

    @Test("loads manifest from exported bundle")
    func canLoadManifest() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 1, cardsPerBoard: 7)
        defer { drainContainer(container); try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        _ = try await exporter.exportVerified(to: destination, from: container)

        let manifest = try BackupExporter.readManifest(at: destination)
        #expect(manifest.entityCounts["Card"] == 7)
        #expect(manifest.entityCounts["Board"] == 1)
        #expect(manifest.version == 1)
    }

    @Test("verifier rejects count mismatch (manifest disagrees with store)")
    func rejectsCountMismatch() async throws {
        let (container, tempDir) = try makeOnDiskContainer(seedBoards: 1, cardsPerBoard: 3)
        defer { drainContainer(container); try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent("export.fenixkanban-backup", isDirectory: true)
        let exporter = BackupExporter()
        _ = try await exporter.exportVerified(to: destination, from: container)

        // Doctor the manifest to claim wildly wrong counts. The store itself
        // is still valid and loadable — the verifier must catch the
        // count-vs-manifest mismatch and throw, not silently accept.
        let doctored = BackupManifest(
            version: 1,
            exportedAt: .now,
            schemaName: "FenixKanban 3",
            entityCounts: ["Board": 99, "Column": 99, "Card": 999, "Label": 99]
        )
        try doctored.encoded().write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)

        await #expect(throws: BackupExporter.ExportError.self) {
            _ = try await exporter.verify(bundleAt: destination)
        }
    }
}
