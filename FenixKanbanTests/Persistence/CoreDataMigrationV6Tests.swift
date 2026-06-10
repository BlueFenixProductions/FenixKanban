import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Proves the v5 → v6 lightweight migration: `Card.label` (to-one) becomes
/// `Card.labels` (many-to-many) via `renamingIdentifier="label"`, and existing
/// to-one data survives as a one-element set.
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

    @Test("v5 store with card.label migrates to card.labels containing that label")
    func migratesLabelDataForward() throws {
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

        // 3. The old to-one label is now a member of the to-many labels set.
        let request = NSFetchRequest<NSManagedObject>(entityName: "Card")
        let migrated = try #require(try newContainer.viewContext.fetch(request).first)
        let labels = try #require(migrated.value(forKey: "labels") as? Set<NSManagedObject>)
        #expect(labels.count == 1)
        #expect(labels.first?.value(forKey: "name") as? String == "Urgent")
    }
}
