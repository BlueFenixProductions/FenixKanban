import Testing
import Foundation
@testable import FenixKanban

@Suite("BackupManifest")
struct BackupManifestTests {

    @Test("encodes/decodes round-trip preserves all fields")
    func roundTrip() throws {
        let original = BackupManifest(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaName: "FenixKanban 3",
            entityCounts: ["Board": 3, "Column": 9, "Card": 47, "Label": 5]
        )

        let data = try original.encoded()
        let decoded = try BackupManifest.decoded(from: data)

        #expect(decoded == original)
    }

    @Test("decode rejects garbage")
    func rejectsGarbage() {
        let garbage = Data("not a manifest".utf8)
        #expect(throws: DecodingError.self) {
            _ = try BackupManifest.decoded(from: garbage)
        }
    }

    @Test("entity counts compared in order-insensitive way via Equatable")
    func dictionaryEquality() {
        let a = BackupManifest(version: 1, exportedAt: .distantPast,
                                schemaName: "x", entityCounts: ["A": 1, "B": 2])
        let b = BackupManifest(version: 1, exportedAt: .distantPast,
                                schemaName: "x", entityCounts: ["B": 2, "A": 1])
        #expect(a == b)
    }
}
