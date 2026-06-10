import Testing
import CoreData
@testable import FenixKanban

@Suite("CoreData v7→v8 Migration")
struct CoreDataMigrationV8Tests {

    @Test("v8 Card gains isWatched + isPinned Booleans; assigneesData unchanged")
    func v8ModelShape() throws {
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let card = try #require(v8.entitiesByName["Card"])
        for name in ["isWatched", "isPinned"] {
            let attr = try #require(card.attributesByName[name])
            #expect(attr.attributeType == .booleanAttributeType)
            #expect(!attr.isOptional)
            #expect(attr.defaultValue as? Bool == false)
        }
        #expect(card.attributesByName["assigneesData"] != nil)
    }

    @Test("lightweight mapping v7→v8 is inferable (additive only)")
    func v7ToV8Inferable() throws {
        let v7 = try migrationTestModel(named: "FenixKanban 7")
        let v8 = try migrationTestModel(named: "FenixKanban 8")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v7, destinationModel: v8)
        #expect(!mapping.entityMappings.isEmpty)
    }

    @Test("current model carries Card.isWatched and Card.isPinned (compiled version is v8)")
    func currentModelHasWatchPinFlags() throws {
        let current = try migrationTestModel(named: nil)
        let card = try #require(current.entitiesByName["Card"])
        #expect(card.attributesByName["isWatched"] != nil)
        #expect(card.attributesByName["isPinned"] != nil)
    }
}
