import Testing
import CoreData
import Foundation
@testable import FenixKanban

@Suite("PersistenceController Store Location", .serialized)
struct PersistenceControllerStoreLocationTests {

    // MARK: - Helpers

    /// Creates a temporary directory, opens a real on-disk NSPersistentContainer
    /// in it, inserts one Board, saves, and returns (tempDir, storeURL, container).
    /// Caller is responsible for teardown.
    private func makeSeededStore(boardName: String) throws -> (dir: URL, url: URL, container: NSPersistentContainer) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("Test.sqlite")

        let container = NSPersistentContainer(
            name: "Seed",
            managedObjectModel: PersistenceController.sharedModel
        )
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil, "Failed to load seed store: \(String(describing: loadError))")

        let ctx = container.viewContext
        let board = Board(context: ctx)
        board.id = UUID()
        board.name = boardName
        board.createdAt = Date()
        board.modifiedAt = Date()
        board.sortOrder = 0
        try ctx.save()

        return (dir, storeURL, container)
    }

    /// Detaches all persistent stores from a container so temp files can be deleted.
    private func detach(_ container: NSPersistentContainer) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    /// Removes a temp directory and all its contents (ignores errors — best-effort cleanup).
    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - migrateStoreIfNeeded: copies seeded store

    @Test("migrateStoreIfNeeded copies a seeded store's data to newURL")
    func migrateStoreIfNeededCopiesData() throws {
        // Seed old store
        let (oldDir, oldURL, oldContainer) = try makeSeededStore(boardName: "Migrated Board")
        detach(oldContainer)
        defer { cleanup(oldDir) }

        // Fresh empty destination directory
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        defer { cleanup(newDir) }
        let newURL = newDir.appendingPathComponent("New.sqlite")

        // Run migration
        PersistenceController.migrateStoreIfNeeded(to: newURL, from: oldURL)

        // Open newURL and assert the Board is there
        let verifyContainer = NSPersistentContainer(
            name: "Verify",
            managedObjectModel: PersistenceController.sharedModel
        )
        let desc = NSPersistentStoreDescription(url: newURL)
        desc.shouldAddStoreAsynchronously = false
        verifyContainer.persistentStoreDescriptions = [desc]
        var verifyError: Error?
        verifyContainer.loadPersistentStores { _, error in verifyError = error }
        defer { detach(verifyContainer) }

        try #require(verifyError == nil, "Failed to open migrated store: \(String(describing: verifyError))")

        let request = NSFetchRequest<NSManagedObject>(entityName: "Board")
        let boards = try verifyContainer.viewContext.fetch(request)
        #expect(boards.count == 1)
        #expect(boards.first?.value(forKey: "name") as? String == "Migrated Board")
    }

    // MARK: - migrateStoreIfNeeded: no-op when newURL already exists

    @Test("migrateStoreIfNeeded does not clobber an existing store at newURL")
    func migrateStoreIfNeededNoOpWhenDestinationExists() throws {
        // Pre-create a store at newURL with distinct data
        let (newDir, newURL, newContainer) = try makeSeededStore(boardName: "Original Board")
        detach(newContainer)
        defer { cleanup(newDir) }

        // Seed oldURL with different data
        let (oldDir, oldURL, oldContainer) = try makeSeededStore(boardName: "Replacement Board")
        detach(oldContainer)
        defer { cleanup(oldDir) }

        // Run migration — must be a no-op because newURL already exists
        PersistenceController.migrateStoreIfNeeded(to: newURL, from: oldURL)

        // Open newURL and assert original data is untouched
        let verifyContainer = NSPersistentContainer(
            name: "VerifyNoOp",
            managedObjectModel: PersistenceController.sharedModel
        )
        let desc = NSPersistentStoreDescription(url: newURL)
        desc.shouldAddStoreAsynchronously = false
        verifyContainer.persistentStoreDescriptions = [desc]
        var verifyError: Error?
        verifyContainer.loadPersistentStores { _, error in verifyError = error }
        defer { detach(verifyContainer) }

        try #require(verifyError == nil)

        let request = NSFetchRequest<NSManagedObject>(entityName: "Board")
        let boards = try verifyContainer.viewContext.fetch(request)
        #expect(boards.count == 1)
        #expect(boards.first?.value(forKey: "name") as? String == "Original Board",
                "newURL data should be untouched; got \(boards.first?.value(forKey: "name") as? String ?? "<nil>")")
    }

    // MARK: - migrateStoreIfNeeded: no-op when neither exists

    @Test("migrateStoreIfNeeded is a no-op when neither old nor new store exists")
    func migrateStoreIfNeededNoOpWhenNeitherExists() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir) }

        let oldURL = tmpDir.appendingPathComponent("OldNonExistent.sqlite")
        let newURL = tmpDir.appendingPathComponent("NewShouldNotAppear.sqlite")

        // Must not throw, must not create newURL
        PersistenceController.migrateStoreIfNeeded(to: newURL, from: oldURL)

        #expect(!FileManager.default.fileExists(atPath: newURL.path),
                "No store should have been created at newURL")
    }

    // MARK: - appGroupStoreURL

    @Test("appGroupStoreURL returns a URL ending in FenixKanban.sqlite, or nil")
    func appGroupStoreURLShape() {
        let url = PersistenceController.appGroupStoreURL()
        if let url = url {
            // The filename must be FenixKanban.sqlite.
            #expect(url.lastPathComponent == "FenixKanban.sqlite")
            // Note: on iOS/macOS the App Group container is mounted under an opaque
            // UUID path (e.g. .../AppGroup/<UUID>/), NOT under a path that contains
            // the literal group identifier string. So we only assert the filename.
        }
        // If nil: the test host lacks the entitlement — that's acceptable; just verify
        // we don't crash and the function returns nil gracefully.
        // (No explicit assertion needed; reaching here without a crash is the test.)
    }
}
