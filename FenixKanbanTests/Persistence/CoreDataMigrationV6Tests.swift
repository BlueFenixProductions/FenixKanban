import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Proves the v5 → v6 lightweight migration: `Card.label` (to-one) is removed
/// and `Card.labels` (many-to-many) is added — an additive change, NOT a
/// rename. CloudKit (NSPersistentCloudKitContainer) forbids rename migrations,
/// so the former `renamingIdentifier="label"` was dropped (Captain's ruling,
/// 2026-06-10): v5-era card→label links are not carried forward by design —
/// v5 was the first-tag-only era and Fizzy re-pulls tags on next sync.
///
/// Both containers use class-stripped model copies (entities resolved to plain
/// NSManagedObject + KVC) so loading two model versions in one process doesn't
/// trip the "multiple NSEntityDescriptions claim subclass Card" warning.
@Suite("CoreData v5→v6 migration", .serialized)
struct CoreDataMigrationV6Tests {

    @Test("current model exposes Card.labels as a to-many relationship")
    func currentModelHasToManyLabels() throws {
        let current = try migrationTestModel(named: nil)
        let card = try #require(current.entitiesByName["Card"])
        let labels = try #require(card.relationshipsByName["labels"],
                                  "Card has no 'labels' relationship — model still at v5")
        #expect(labels.isToMany)
        #expect(labels.destinationEntity?.name == "Label")
        let label = try #require(current.entitiesByName["Label"])
        #expect(label.relationshipsByName["cards"]?.inverseRelationship?.name == "labels")
    }

    @Test("v5 on-disk store migrates forward; Label entities survive")
    func migratesV5StoreForward() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v6-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        }

        // 1. Seed an on-disk store using the OLD v5 model, pure KVC.
        let v5 = try migrationTestModel(named: "FenixKanban 5")
        let oldContainer = NSPersistentContainer(name: "MigV5", managedObjectModel: v5)
        let oldDesc = NSPersistentStoreDescription(url: storeURL)
        oldDesc.shouldAddStoreAsynchronously = false
        oldContainer.persistentStoreDescriptions = [oldDesc]
        var loadError: Error?
        oldContainer.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)

        let oldCtx = oldContainer.viewContext
        let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: oldCtx)
        label.setValue(UUID(), forKey: "id")
        label.setValue("Urgent", forKey: "name")
        label.setValue("#FF0000", forKey: "colorHex")
        let card = NSEntityDescription.insertNewObject(forEntityName: "Card", into: oldCtx)
        card.setValue(UUID(), forKey: "id")
        card.setValue("Migrating card", forKey: "title")
        card.setValue(label, forKey: "label")
        try oldCtx.save()
        for store in oldContainer.persistentStoreCoordinator.persistentStores {
            try oldContainer.persistentStoreCoordinator.remove(store)
        }

        // 2. Re-open with the CURRENT model; lightweight migration must run.
        let current = try migrationTestModel(named: nil)
        let newContainer = NSPersistentContainer(name: "MigV6", managedObjectModel: current)
        let newDesc = NSPersistentStoreDescription(url: storeURL)
        newDesc.shouldAddStoreAsynchronously = false
        newDesc.shouldMigrateStoreAutomatically = true
        newDesc.shouldInferMappingModelAutomatically = true
        newContainer.persistentStoreDescriptions = [newDesc]
        var migError: Error?
        newContainer.loadPersistentStores { _, error in migError = error }
        try #require(migError == nil, "lightweight migration failed: \(String(describing: migError))")
        // Registered after the file-deletion defer, so it runs first (LIFO):
        // detach the store from its coordinator before the sqlite files go.
        defer {
            for store in newContainer.persistentStoreCoordinator.persistentStores {
                try? newContainer.persistentStoreCoordinator.remove(store)
            }
        }

        // 3. The card and the Label entity (with its attributes) survive the
        //    migration. The old to-one card→label LINK is intentionally NOT
        //    carried into `labels`: renaming identifiers are forbidden on
        //    CloudKit models (rename migrations crash real devices with
        //    "CloudKit integration forbids renaming"), so v5→current is
        //    remove-label/add-labels and the link is dropped by design.
        //    Fizzy re-syncs tags on the next pull.
        let request = NSFetchRequest<NSManagedObject>(entityName: "Card")
        let migrated = try #require(try newContainer.viewContext.fetch(request).first)
        #expect(migrated.value(forKey: "title") as? String == "Migrating card")
        let labelRequest = NSFetchRequest<NSManagedObject>(entityName: "Label")
        let survivingLabel = try #require(try newContainer.viewContext.fetch(labelRequest).first)
        #expect(survivingLabel.value(forKey: "name") as? String == "Urgent")
        #expect(survivingLabel.value(forKey: "colorHex") as? String == "#FF0000")
    }
}
