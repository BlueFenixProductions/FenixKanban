import Testing
import CoreData
@testable import FenixKanban

/// CloudKit (NSPersistentCloudKitContainer) forbids rename migrations — its
/// schema is additive-only. A renaming identifier on any property of a
/// usedWithCloudKit model crashes real devices at store-migration time with
/// "CloudKit integration forbids renaming X to Y" (caught live on-device,
/// 2026-06-10; CI never sees it because test harnesses use useCloudKit: false).
@Suite("CloudKit model compatibility")
struct CloudKitModelCompatibilityTests {

    @Test("no model version carries an explicit renaming identifier",
          arguments: ["FenixKanban 6", "FenixKanban 7", "FenixKanban 8"])
    func noRenamingIdentifiers(version: String) throws {
        let model = try migrationTestModel(named: version)
        for entity in model.entities {
            for property in entity.properties {
                // renamingIdentifier falls back to the property name when no
                // explicit elementID is set; an explicit rename is any value
                // that differs.
                #expect(property.renamingIdentifier == nil || property.renamingIdentifier == property.name,
                        "\(entity.name ?? "?").\(property.name) carries renaming identifier \(property.renamingIdentifier ?? "nil") — forbidden on a CloudKit model")
            }
            #expect(entity.renamingIdentifier == nil || entity.renamingIdentifier == entity.name,
                    "\(entity.name ?? "?") carries renaming identifier \(entity.renamingIdentifier ?? "nil") — forbidden on a CloudKit model")
        }
    }

    @Test("current model carries no explicit renaming identifier")
    func currentModelClean() throws {
        let model = try migrationTestModel(named: nil)
        for entity in model.entities {
            for property in entity.properties {
                #expect(property.renamingIdentifier == nil || property.renamingIdentifier == property.name,
                        "\(entity.name ?? "?").\(property.name) carries renaming identifier \(property.renamingIdentifier ?? "nil") — forbidden on a CloudKit model")
            }
            #expect(entity.renamingIdentifier == nil || entity.renamingIdentifier == entity.name)
        }
    }
}
