import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Proves the v8 → v9 lightweight migration: Card gains `lifecycleStatusRaw`
/// (String, non-optional, default "active") and `closedAt` (Date, optional);
/// two new local-only cache entities are added: CardStep and CachedComment.
///
/// CardStep carries a to-one relationship `card` → Card with Nullify delete
/// rule and NO inverse on Card (deliberate: keeps it local-only and outside
/// CloudKit's inverse requirements; these rows are Fizzy-refetchable caches).
///
/// CachedComment has no relationships. Neither new entity is usedWithCloudKit
/// in the per-entity sync sense — they inherit the model-level flag but have
/// no CloudKit record types established.
///
/// Uses class-stripped model copies (entities resolved to plain NSManagedObject)
/// so loading two model versions in one process doesn't trip the
/// "multiple NSEntityDescriptions claim subclass Card" warning.
@Suite("CoreData v8→v9 Migration", .serialized)
struct CoreDataMigrationV9Tests {

    // MARK: - Shape tests

    @Test("v9 Card gains lifecycleStatusRaw (String, non-optional, default 'active') and closedAt (Date, optional)")
    func v9CardShape() throws {
        let v9 = try migrationTestModel(named: "FenixKanban 9")
        let card = try #require(v9.entitiesByName["Card"])

        // lifecycleStatusRaw: String, non-optional, default "active"
        let lifecycleAttr = try #require(card.attributesByName["lifecycleStatusRaw"],
                                         "Card has no 'lifecycleStatusRaw' attribute")
        #expect(lifecycleAttr.attributeType == .stringAttributeType)
        #expect(!lifecycleAttr.isOptional)
        #expect(lifecycleAttr.defaultValue as? String == "active")

        // closedAt: Date, optional, no default
        let closedAtAttr = try #require(card.attributesByName["closedAt"],
                                        "Card has no 'closedAt' attribute")
        #expect(closedAtAttr.attributeType == .dateAttributeType)
        #expect(closedAtAttr.isOptional)
    }

    @Test("v9 CardStep entity has correct attributes and card relationship")
    func v9CardStepShape() throws {
        let v9 = try migrationTestModel(named: "FenixKanban 9")
        let step = try #require(v9.entitiesByName["CardStep"],
                                "v9 model missing CardStep entity")

        // fizzyStepID: String, optional
        let stepID = try #require(step.attributesByName["fizzyStepID"])
        #expect(stepID.attributeType == .stringAttributeType)
        #expect(stepID.isOptional)

        // content: String, non-optional, default ""
        let content = try #require(step.attributesByName["content"])
        #expect(content.attributeType == .stringAttributeType)
        #expect(!content.isOptional)
        #expect(content.defaultValue as? String == "")

        // completed: Boolean, non-optional, default NO
        let completed = try #require(step.attributesByName["completed"])
        #expect(completed.attributeType == .booleanAttributeType)
        #expect(!completed.isOptional)
        #expect(completed.defaultValue as? Bool == false)

        // sortOrder: Integer 32, non-optional, default 0
        let sortOrder = try #require(step.attributesByName["sortOrder"])
        #expect(sortOrder.attributeType == .integer32AttributeType)
        #expect(!sortOrder.isOptional)
        #expect(sortOrder.defaultValue as? Int == 0)

        // pendingWrite: Boolean, non-optional, default NO
        let pendingWrite = try #require(step.attributesByName["pendingWrite"])
        #expect(pendingWrite.attributeType == .booleanAttributeType)
        #expect(!pendingWrite.isOptional)
        #expect(pendingWrite.defaultValue as? Bool == false)

        // card: to-one Card, optional, Nullify delete rule
        let cardRel = try #require(step.relationshipsByName["card"])
        #expect(!cardRel.isToMany)
        #expect(cardRel.isOptional)
        #expect(cardRel.deleteRule == .nullifyDeleteRule)
        #expect(cardRel.destinationEntity?.name == "Card")
    }

    @Test("v9 CachedComment entity has correct attributes and no relationships")
    func v9CachedCommentShape() throws {
        let v9 = try migrationTestModel(named: "FenixKanban 9")
        let comment = try #require(v9.entitiesByName["CachedComment"],
                                   "v9 model missing CachedComment entity")

        // fizzyCommentID: String, optional
        let commentID = try #require(comment.attributesByName["fizzyCommentID"])
        #expect(commentID.attributeType == .stringAttributeType)
        #expect(commentID.isOptional)

        // cardFizzyNumber: Integer 64, non-optional, default 0
        let cardNum = try #require(comment.attributesByName["cardFizzyNumber"])
        #expect(cardNum.attributeType == .integer64AttributeType)
        #expect(!cardNum.isOptional)
        #expect(cardNum.defaultValue as? Int == 0)

        // body: String, non-optional, default ""
        let body = try #require(comment.attributesByName["body"])
        #expect(body.attributeType == .stringAttributeType)
        #expect(!body.isOptional)
        #expect(body.defaultValue as? String == "")

        // creatorName: String, optional
        let creatorName = try #require(comment.attributesByName["creatorName"])
        #expect(creatorName.attributeType == .stringAttributeType)
        #expect(creatorName.isOptional)

        // createdAt: Date, optional
        let createdAt = try #require(comment.attributesByName["createdAt"])
        #expect(createdAt.attributeType == .dateAttributeType)
        #expect(createdAt.isOptional)

        // pendingWrite: Boolean, non-optional, default NO
        let pendingWrite = try #require(comment.attributesByName["pendingWrite"])
        #expect(pendingWrite.attributeType == .booleanAttributeType)
        #expect(!pendingWrite.isOptional)
        #expect(pendingWrite.defaultValue as? Bool == false)

        // no relationships
        #expect(comment.relationshipsByName.isEmpty)
    }

    // MARK: - Migration inferable

    @Test("lightweight mapping v8→v9 is inferable (additive only)")
    func v8ToV9Inferable() throws {
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let v9 = try migrationTestModel(named: "FenixKanban 9")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v8, destinationModel: v9)
        #expect(!mapping.entityMappings.isEmpty)
    }

    // MARK: - On-disk migration

    @Test("v8 on-disk store migrates to v9; Card.title survives; lifecycleStatusRaw backfilled 'active'")
    func migratesV8StoreForward() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v9-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        }

        // 1. Seed an on-disk store using the v8 model, pure KVC.
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let oldContainer = NSPersistentContainer(name: "MigV8Seed", managedObjectModel: v8)
        let oldDesc = NSPersistentStoreDescription(url: storeURL)
        oldDesc.shouldAddStoreAsynchronously = false
        oldContainer.persistentStoreDescriptions = [oldDesc]
        var loadError: Error?
        oldContainer.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)

        let oldCtx = oldContainer.viewContext
        let card = NSEntityDescription.insertNewObject(forEntityName: "Card", into: oldCtx)
        card.setValue(UUID(), forKey: "id")
        card.setValue("Pre-migration card", forKey: "title")
        try oldCtx.save()

        // Detach stores LIFO before the sqlite files are deleted.
        defer {
            for store in oldContainer.persistentStoreCoordinator.persistentStores {
                try? oldContainer.persistentStoreCoordinator.remove(store)
            }
        }
        for store in oldContainer.persistentStoreCoordinator.persistentStores {
            try oldContainer.persistentStoreCoordinator.remove(store)
        }

        // 2. Re-open with the v9 model; lightweight migration must run.
        let v9 = try migrationTestModel(named: "FenixKanban 9")
        let newContainer = NSPersistentContainer(name: "MigV9", managedObjectModel: v9)
        let newDesc = NSPersistentStoreDescription(url: storeURL)
        newDesc.shouldAddStoreAsynchronously = false
        newDesc.shouldMigrateStoreAutomatically = true
        newDesc.shouldInferMappingModelAutomatically = true
        newContainer.persistentStoreDescriptions = [newDesc]
        var migError: Error?
        newContainer.loadPersistentStores { _, error in migError = error }
        try #require(migError == nil, "lightweight migration failed: \(String(describing: migError))")
        defer {
            for store in newContainer.persistentStoreCoordinator.persistentStores {
                try? newContainer.persistentStoreCoordinator.remove(store)
            }
        }

        // 3. Verify Card.title survived and lifecycleStatusRaw was backfilled.
        let request = NSFetchRequest<NSManagedObject>(entityName: "Card")
        let migrated = try #require(try newContainer.viewContext.fetch(request).first)
        #expect(migrated.value(forKey: "title") as? String == "Pre-migration card")
        // Non-optional attribute with default "active" is backfilled on migration.
        #expect(migrated.value(forKey: "lifecycleStatusRaw") as? String == "active")
    }
}
