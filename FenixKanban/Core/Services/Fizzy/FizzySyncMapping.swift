import Foundation

/// Pure helpers shared by the Fizzy sync engine: column-name normalization
/// for case-insensitive trimmed matching, and deterministic label-color
/// derivation so auto-created labels stay visually stable across reinstalls.
enum FizzySyncMapping {

    /// Lowercased + whitespace-trimmed name, used for matching local Columns
    /// to remote Fizzy columns. Phase 4a does not track `fizzyColumnID` on the
    /// local Column entity, so name-equality is the only join key — renaming
    /// a column on either side will produce a phantom local column on the
    /// next sync. Documented MVP limitation.
    static func normalizedColumnName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Deterministic `#RRGGBB` hex for an auto-created Label, derived from
    /// the tag name. Different reinstalls produce the same color for the
    /// same tag, so users get visual consistency.
    ///
    /// Uses a simple FNV-1a-ish hash over UTF-8 bytes mapped to 24 bits.
    /// Not Foundation's `String.hashValue` because that's randomized per
    /// process launch and would defeat determinism.
    static func labelColorHex(forName name: String) -> String {
        var hash: UInt32 = 0x811c9dc5  // FNV-1a 32-bit offset basis
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193  // FNV-1a 32-bit prime
        }
        let r = UInt8((hash >> 16) & 0xFF)
        let g = UInt8((hash >> 8)  & 0xFF)
        let b = UInt8(hash         & 0xFF)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
