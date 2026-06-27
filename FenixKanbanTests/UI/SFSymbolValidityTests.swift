import Foundation
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Sweeps every `.swift` file in the app source tree, extracts each
/// `systemImage:` / `systemName:` / `systemImageName:` string literal,
/// and asserts it resolves to a real SF Symbol. Phantom symbol names
/// (e.g. `ticket.slash`) compile fine and only surface as a blank icon
/// plus a runtime console warning on device — this test makes them a
/// CI failure instead.
@Suite("SF Symbol validity")
struct SFSymbolValidityTests {

    @Test("Every systemImage/systemName literal in app source resolves to a real SF Symbol")
    func allSymbolLiteralsResolve() throws {
        let appSource = try #require(
            Self.appSourceDirectory(),
            "Could not locate the FenixKanban/ app source tree from #filePath — this sweep requires the repo checkout."
        )

        let candidates = try Self.symbolCandidates(under: appSource)

        // If extraction ever finds nothing, the regex broke — fail loudly
        // rather than passing vacuously.
        #expect(!candidates.isEmpty, "Symbol sweep extracted zero candidates — extraction logic is broken.")

        for candidate in candidates {
            #expect(
                Self.symbolResolves(candidate.name),
                "\"\(candidate.name)\" (\(candidate.file):\(candidate.line)) is not a valid SF Symbol — it will render blank at runtime."
            )
        }
    }

    // MARK: - Source discovery

    /// Walks up from this file's path to the directory containing
    /// `FenixKanban.xcodeproj`, then returns its `FenixKanban/` subdirectory.
    private static func appSourceDirectory() -> URL? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let projectMarker = directory.appendingPathComponent("FenixKanban.xcodeproj")
            if fileManager.fileExists(atPath: projectMarker.path) {
                let appSource = directory.appendingPathComponent("FenixKanban")
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: appSource.path, isDirectory: &isDirectory)
                return (exists && isDirectory.boolValue) ? appSource : nil
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Extraction

    struct SymbolCandidate {
        let name: String
        let file: String
        let line: Int
    }

    /// Matches the parameter label introducing an SF Symbol name:
    /// `systemImage:` (SwiftUI Label), `systemName:` (Image), and
    /// `systemImageName:` (App Intents ShortcutsLink et al.).
    private static let parameterLabel = /system(?:ImageName|Image|Name)\s*:/

    /// SF Symbol names are lowercase letters, digits, and dots
    /// (e.g. "arrow.up", "square.grid.3x3", "ticket.fill"). Only quoted
    /// strings of that shape are treated as candidates, so titles and
    /// format-string interpolations on the same line are skipped.
    private static let symbolLiteral = /"([a-z0-9]+(?:\.[a-z0-9]+)*)"/

    static func symbolCandidates(under root: URL) throws -> [SymbolCandidate] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Could not enumerate \(root.path)"
        )

        var candidates: [SymbolCandidate] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                candidates.append(contentsOf: symbolLiterals(in: line).map {
                    SymbolCandidate(name: $0, file: url.lastPathComponent, line: index + 1)
                })
            }
        }
        return candidates
    }

    /// Extracts every symbol-shaped string literal after a
    /// `systemImage:`/`systemName:` label on the line. Taking the whole
    /// remainder of the line deliberately captures BOTH branches of
    /// ternaries like `systemImage: cond ? "a" : "b"`.
    static func symbolLiterals(in line: String) -> [String] {
        guard let label = line.firstMatch(of: parameterLabel) else { return [] }
        return line[label.range.upperBound...].matches(of: symbolLiteral).map { String($0.1) }
    }

    // MARK: - Resolution

    static func symbolResolves(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return false
        #endif
    }
}
