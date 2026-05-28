import Foundation

/// Captured at export time. The verifier compares re-derived counts against
/// these to confirm the export wrote everything intact.
struct BackupManifest: Codable, Equatable {
    /// Bump if the on-disk format changes incompatibly.
    let version: Int
    let exportedAt: Date
    /// Human-readable schema identifier (e.g. "FenixKanban 3"). Informational —
    /// the loader doesn't reject on mismatch.
    let schemaName: String
    /// Entity name → row count.
    let entityCounts: [String: Int]

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> BackupManifest {
        try Self.decoder.decode(BackupManifest.self, from: data)
    }
}
