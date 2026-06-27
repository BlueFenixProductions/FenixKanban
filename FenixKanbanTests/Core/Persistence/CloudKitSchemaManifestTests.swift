import Testing
import CoreData
@testable import FenixKanban

@Suite("CloudKit schema surface guard (#20)")
struct CloudKitSchemaSurfaceTests {

    @Test("live surface matches the pinned manifest")
    func liveSurfaceMatchesPinnedManifest() {
        let actual = CloudKitSchemaManifest.surface(of: PersistenceController.sharedModel)
        #expect(
            actual == CloudKitSchemaManifest.expected,
            "CloudKit schema surface has changed. Run initializeCloudKitSchema() and update the expected manifest in CloudKitSchemaManifest.swift"
        )
    }

    @Test("surface extracts a known attribute")
    func surfaceExtractsKnownAttribute() throws {
        let actual = CloudKitSchemaManifest.surface(of: PersistenceController.sharedModel)
        let cardEntry = try #require(actual["Card"])
        #expect(cardEntry.contains { $0.contains("title") })
    }

    @Test("surface extracts a known relationship")
    func surfaceExtractsKnownRelationship() throws {
        let actual = CloudKitSchemaManifest.surface(of: PersistenceController.sharedModel)
        let cardEntry = try #require(actual["Card"])
        #expect(cardEntry.contains { $0.hasPrefix("r:") && $0.contains("column") })
    }
}
