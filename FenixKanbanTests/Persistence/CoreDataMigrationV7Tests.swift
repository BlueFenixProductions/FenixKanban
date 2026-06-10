import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Proves the v6 → v7 lightweight migration: Card gains one optional Binary
/// attribute `assigneesData` (JSON blob of `[CardAssignee]`). Additive-only,
/// so the inferred mapping model must exist and the rest of Card is unchanged.
///
/// Uses class-stripped model copies (entities resolved to plain
/// NSManagedObject) so loading two model versions in one process doesn't
/// trip the "multiple NSEntityDescriptions claim subclass Card" warning.
@Suite("CoreData v6→v7 Migration")
struct CoreDataMigrationV7Tests {

    @Test("current model carries Card.assigneesData (compiled version is v7)")
    func currentModelHasAssigneesData() throws {
        let current = try migrationTestModel(named: nil)
        let card = try #require(current.entitiesByName["Card"])
        let attr = try #require(card.attributesByName["assigneesData"],
                                "Card has no 'assigneesData' attribute — current model regressed below v7")
        #expect(attr.attributeType == .binaryDataAttributeType)
        #expect(attr.isOptional)
    }

    @Test("v7 Card gains optional binary assigneesData; rest unchanged")
    func v7ModelShape() throws {
        let v7 = try migrationTestModel(named: "FenixKanban 7")
        let card = try #require(v7.entitiesByName["Card"])
        let attr = try #require(card.attributesByName["assigneesData"])
        #expect(attr.attributeType == .binaryDataAttributeType)
        #expect(attr.isOptional)
        // labels relationship untouched
        let labels = try #require(card.relationshipsByName["labels"])
        #expect(labels.isToMany)
    }

    @Test("lightweight mapping v6→v7 is inferable (additive only)")
    func v6ToV7Inferable() throws {
        let v6 = try migrationTestModel(named: "FenixKanban 6")
        let v7 = try migrationTestModel(named: "FenixKanban 7")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v6, destinationModel: v7)
        #expect(!mapping.entityMappings.isEmpty)
    }
}
