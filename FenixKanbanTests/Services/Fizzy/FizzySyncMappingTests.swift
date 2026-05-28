import Testing
import Foundation
@testable import FenixKanban

@Suite("FizzySyncMapping")
struct FizzySyncMappingTests {

    @Test("normalizedColumnName lowercases and trims")
    func normalizeColumnName() {
        #expect(FizzySyncMapping.normalizedColumnName("In Progress") == "in progress")
        #expect(FizzySyncMapping.normalizedColumnName("  TRIAGE ") == "triage")
        #expect(FizzySyncMapping.normalizedColumnName("review") == "review")
        #expect(FizzySyncMapping.normalizedColumnName("") == "")
    }

    @Test("labelColorHex is deterministic for the same name")
    func labelColorIsDeterministic() {
        #expect(FizzySyncMapping.labelColorHex(forName: "bug") == FizzySyncMapping.labelColorHex(forName: "bug"))
        #expect(FizzySyncMapping.labelColorHex(forName: "Bug") != FizzySyncMapping.labelColorHex(forName: "bug"),
                "Case-sensitive — \"Bug\" and \"bug\" produce different colors. Engine normalizes case at lookup time.")
    }

    @Test("labelColorHex returns a 7-char #RRGGBB string")
    func labelColorFormat() {
        let hex = FizzySyncMapping.labelColorHex(forName: "test-label")
        #expect(hex.count == 7)
        #expect(hex.hasPrefix("#"))
        // All chars after # must be 0-9 or A-F
        let body = String(hex.dropFirst())
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        #expect(body.unicodeScalars.allSatisfy { allowed.contains($0) })
    }
}
