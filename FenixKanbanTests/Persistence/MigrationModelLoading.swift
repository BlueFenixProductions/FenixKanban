import Testing
import CoreData
import Foundation
@testable import FenixKanban

/// Loads a versioned managed object model from the compiled .momd for
/// migration tests. Pass `nil` to load the CURRENT compiled model.
///
/// Returns a class-stripped copy (entities resolved to plain
/// NSManagedObject) so loading two model versions in one process doesn't
/// trip the "multiple NSEntityDescriptions claim subclass Card" warning.
func migrationTestModel(named name: String?) throws -> NSManagedObjectModel {
    let bundle = Bundle(for: PluginRegistry.self)
    let momd = try #require(bundle.url(forResource: "FenixKanban", withExtension: "momd"))
    let url = name.map { momd.appendingPathComponent("\($0).mom") } ?? momd
    let model = try #require(NSManagedObjectModel(contentsOf: url))
    let stripped = model.copy() as! NSManagedObjectModel
    for entity in stripped.entities { entity.managedObjectClassName = "NSManagedObject" }
    return stripped
}
